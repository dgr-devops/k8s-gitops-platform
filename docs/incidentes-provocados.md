# Incidentes provocados

Todos los incidentes de este documento se **provocaron de verdad** sobre el cluster kind `gitops`
(1 control-plane + 2 workers, Argo CD gestionando todo desde GitHub) el 24/11/2026. Las salidas son
capturas reales de `kubectl`, `curl` y la API de Alertmanager; solo se han recortado líneas repetidas.
Los cambios de configuración se hicieron **como en un flujo GitOps real**: commit en este repo, push
y Argo CD sincroniza (salvo el incidente 6, que es un cambio manual para ver el *self-heal*).

| # | Incidente | Síntoma | Alerta |
|---|-----------|---------|--------|
| 1 | Etiqueta de imagen inexistente | `ImagePullBackOff`, rollout atascado | `DemoAppPodNotReady` |
| 2 | Readiness que falla | Pod `0/1 Running`, rollout atascado | `DemoAppPodNotReady` |
| 3 | `OOMKilled` por límite de memoria bajo | `OOMKilled` / `CrashLoopBackOff` | `DemoAppOOMKilled` |
| 4 | Secreto roto (nombre mal escrito + SealedSecret sin descifrar) | `CreateContainerConfigError` | `DemoAppPodNotReady` |
| 5 | Ingress roto (IngressClass inexistente) | `404` de nginx con TLS válido | (ninguna: la app está sana) |
| 6 | Deriva manual y *self-heal* de Argo CD | `OutOfSync` durante ~1 s | — |

Un patrón común: la estrategia `RollingUpdate` por defecto mantiene el pod antiguo sirviendo
tráfico mientras el nuevo no esté listo, así que en los incidentes 1–4 **la app no llegó a caer**;
lo que se rompió fue el despliegue. Eso es precisamente lo que detectan la salud de Argo CD
(`Progressing`) y las alertas.

---

## Incidente 1 — Etiqueta de imagen inexistente

**Cambio provocado:** `envs/dev/app-values.yaml` → `image.tag: v9.9.9` (commit y push).

**Síntomas:** el pod nuevo no arranca y el rollout no termina. Argo CD queda `Synced` pero
`Progressing` (no `Healthy`).

**Diagnóstico:**

```text
$ kubectl -n demo-dev get pods
NAME                            READY   STATUS             RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running            0          95s
demo-app-dev-6c9d769c4f-kslrz   0/1     ImagePullBackOff   0          48s

$ kubectl -n argocd get app demo-app-dev
NAME           SYNC STATUS   HEALTH STATUS
demo-app-dev   Synced        Progressing

$ curl https://app-dev.local (el pod antiguo sigue sirviendo)
{"message": "Hola desde dev", "version": "v1.0.0", "hostname": "demo-app-dev-6965859569-g8pzf", "secret_configured": true}
$ kubectl -n demo-dev describe pod demo-app-dev-6c9d769c4f-kslrz | tail -6
  Normal   Scheduled  52s                default-scheduler  Successfully assigned demo-dev/demo-app-dev-6c9d769c4f-kslrz to gitops-worker2
  Normal   BackOff    25s (x2 over 50s)  kubelet            spec.containers{app}: Back-off pulling image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9"
  Warning  Failed     25s (x2 over 50s)  kubelet            spec.containers{app}: Error: ImagePullBackOff
  Normal   Pulling    13s (x3 over 51s)  kubelet            spec.containers{app}: Pulling image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9"
  Warning  Failed     13s (x3 over 51s)  kubelet            spec.containers{app}: Failed to pull image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to pull and unpack image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to resolve reference "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Adgr-devops%2Fk8s-gitops-app%3Apull&service=ghcr.io: 403 Forbidden
  Warning  Failed     13s (x3 over 51s)  kubelet            spec.containers{app}: Error: ErrImagePull

$ kubectl -n demo-dev get events --field-selector reason=Failed | tail -3
13s         Warning   Failed   pod/demo-app-dev-6c9d769c4f-kslrz   Failed to pull image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to pull and unpack image "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to resolve reference "ghcr.io/dgr-devops/k8s-gitops-app:v9.9.9": failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Adgr-devops%2Fk8s-gitops-app%3Apull&service=ghcr.io: 403 Forbidden
13s         Warning   Failed   pod/demo-app-dev-6c9d769c4f-kslrz   Error: ErrImagePull
25s         Warning   Failed   pod/demo-app-dev-6c9d769c4f-kslrz   Error: ImagePullBackOff
$ git revert + push; kubectl -n demo-dev get pods
NAME                            READY   STATUS    RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running   0          4m6s
NAME           SYNC STATUS   HEALTH STATUS
demo-app-dev   Synced        Healthy

```

**Causa raíz:** la etiqueta `v9.9.9` no existe en el registro (el servidor responde 403 al pedir el
token anónimo para un repositorio/etiqueta inexistente o privado). El kubelet entra en
`ErrImagePull` → `ImagePullBackOff` con espera exponencial.

**Arreglo:** `git revert` del commit y push; Argo CD aplica el valor anterior y el ReplicaSet
fallido se elimina (la última captura muestra `Synced`/`Healthy` y un solo pod).

**Prevención:**
- Que el CI de la app sea quien escribe la etiqueta (`sha-<commit>`), no una persona a mano: solo
  existen etiquetas publicadas.
- Revisión por PR en el repo GitOps y `kubectl rollout status`/Argo CD como puerta antes de promocionar a prod.
- Mantener `maxUnavailable: 0`/`RollingUpdate` (el pod antiguo siguió sirviendo, como se ve en el `curl`).

---

## Incidente 2 — Readiness que falla

**Cambio provocado:** `app.failReadiness: true` en dev (la app devuelve 503 en `/readyz`).

**Síntomas:** el pod nuevo está `Running` pero `0/1`; no recibe tráfico (el Service solo tiene el
endpoint del pod antiguo). Tras 1 minuto salta `DemoAppPodNotReady`.

**Diagnóstico:**

```text
$ kubectl -n demo-dev get pods
NAME                            READY   STATUS    RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running   0          4m38s
demo-app-dev-7c8f7656c4-7trqf   0/1     Running   0          21s

$ kubectl -n demo-dev rollout status deploy/demo-app-dev --timeout=10s
Waiting for deployment "demo-app-dev" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition

$ kubectl -n demo-dev describe pod demo-app-dev-7c8f7656c4-7trqf | tail -4
  Normal   Created    30s                kubelet            spec.containers{app}: Container created
  Normal   Started    30s                kubelet            spec.containers{app}: Container started
  Warning  Unhealthy  30s (x2 over 30s)  kubelet            spec.containers{app}: Readiness probe failed: Get "http://10.244.1.13:8080/readyz": dial tcp 10.244.1.13:8080: connect: connection refused
  Warning  Unhealthy  5s (x5 over 25s)   kubelet            spec.containers{app}: Readiness probe failed: HTTP probe failed with statuscode: 503

$ kubectl -n demo-dev exec <pod> -- python (GET /readyz)
HTTP Error 503: Service Unavailable

Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME           ENDPOINTS          AGE
demo-app-dev   10.244.1.10:8080   7m9s
$ curl alertmanager /api/v2/alerts (filtrado)
DemoAppPodNotReady warning demo-app-dev-6c9d769c4f-kslrz active 2026-11-24T19:29:32.562Z

$ (de nuevo, tras el minuto de gracia)
DemoAppPodNotReady warning demo-app-dev-7c8f7656c4-7trqf active 2026-11-24T19:33:02.562Z
$ git revert + push

```

**Causa raíz:** la sonda de readiness recibe `503`. Un contenedor `Running` no implica que esté
listo: el kubelet lo saca de los endpoints hasta que la sonda pase.

**Arreglo:** revertir el commit; el pod nuevo se sustituye por uno sano y desaparece la alerta.

**Prevención:** la regla `DemoAppPodNotReady` (`platform/monitoring-rules/demo-app-rules.yaml`)
avisa a los 1–2 minutos; probar los cambios de sondas primero en dev; `progressDeadlineSeconds` para
que el despliegue se marque como fallido de forma explícita.

---

## Incidente 3 — OOMKilled por límite de memoria bajo

**Cambio provocado:** `resources.limits.memory` (y `requests`) a `4Mi` y después a `12Mi` en dev.

**Síntomas:** pods en `CrashLoopBackOff`. Con `4Mi` el proceso ni llega a arrancar
(`StartError: container init was OOM-killed`, código 128); con `12Mi` arranca y el kernel lo mata
(`OOMKilled`, código 137). Salta `DemoAppOOMKilled`.

**Diagnóstico:**

```text
$ kubectl -n demo-dev get pods
NAME                            READY   STATUS             RESTARTS      AGE
demo-app-dev-656474bc4b-4ztx8   0/1     CrashLoopBackOff   2 (11s ago)   24s
demo-app-dev-6965859569-g8pzf   1/1     Running            0             11m

$ kubectl -n demo-dev describe pod demo-app-dev-656474bc4b-4ztx8 | grep -A8 'Last State'
    Last State:     Terminated
      Reason:       StartError
      Message:      failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: container init was OOM-killed (memory limit too low?)
      Exit Code:    128
      Started:      Thu, 01 Jan 1970 01:00:00 +0100
      Finished:     Tue, 24 Nov 2026 20:38:06 +0100
    Ready:          False
    Restart Count:  2
    Limits:

$ kubectl -n demo-dev get pod -o jsonpath (reason)
StartError exit=128

$ kubectl -n argocd get app demo-app-dev
NAME           SYNC STATUS   HEALTH STATUS
demo-app-dev   Synced        Progressing
$ kubectl -n demo-dev get pods
NAME                            READY   STATUS      RESTARTS     AGE
demo-app-dev-6965859569-g8pzf   1/1     Running     0            11m
demo-app-dev-69dbdcbf98-kmrfb   0/1     OOMKilled   1 (8s ago)   10s

$ kubectl -n demo-dev describe pod demo-app-dev-69dbdcbf98-kmrfb | grep -A6 'Last State'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Tue, 24 Nov 2026 20:38:34 +0100
      Finished:     Tue, 24 Nov 2026 20:38:36 +0100
    Ready:          False
    Restart Count:  1

$ kubectl -n demo-dev top pod (si metrics-server)
error: Metrics API not available

$ alertas en Alertmanager
DemoAppOOMKilled warning demo-app-dev-656474bc4b-4ztx8 active

$ tras el arreglo
NAME                            READY   STATUS    RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running   0          11m
NAME           SYNC STATUS   HEALTH STATUS
demo-app-dev   Synced        Healthy

```

**Causa raíz:** el *cgroup* de memoria del contenedor se queda sin margen y el kernel mata el
proceso. Python con un servidor HTTP necesita más de ~12 MiB en reposo; el chart usa `64Mi`.

**Arreglo:** eliminar el override de recursos y volver a los valores del chart (64Mi).

**Prevención:** dimensionar con datos (Prometheus: `container_memory_working_set_bytes`), mantener
`requests` ≈ uso típico y `limits` con margen, y vigilar la alerta `DemoAppOOMKilled`. Un límite
absurdo en un PR debería saltar en revisión: se puede añadir una validación (Kyverno/`kubeconform`
con reglas propias) que rechace límites por debajo de un mínimo.

---

## Incidente 4 — Secreto roto

**Cambios provocados:**
1. `app.existingSecret: demo-app-secret-typo` (nombre mal escrito) en dev.
2. Un `SealedSecret` cifrado para el namespace `demo-prod` aplicado en `demo-dev` (simula copiar y pegar un secreto sellado de otro entorno).

**Síntomas:** el pod nuevo se queda en `CreateContainerConfigError`; el `SealedSecret` copiado
no genera `Secret`.

**Diagnóstico:**

```text
$ kubectl -n demo-dev get pods
NAME                            READY   STATUS                       RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running                      0          12m
demo-app-dev-6d7f695cc8-5gxzd   0/1     CreateContainerConfigError   0          11s

$ kubectl -n demo-dev describe pod demo-app-dev-6d7f695cc8-5gxzd | tail -3
  Normal   Scheduled  11s                default-scheduler  Successfully assigned demo-dev/demo-app-dev-6d7f695cc8-5gxzd to gitops-worker2
  Normal   Pulled     10s (x2 over 10s)  kubelet            spec.containers{app}: Container image "ghcr.io/dgr-devops/k8s-gitops-app:v1.0.0" already present on machine and can be accessed by the pod
  Warning  Failed     10s (x2 over 10s)  kubelet            spec.containers{app}: Error: secret "demo-app-secret-typo" not found

$ kubectl -n demo-dev get secret
NAME              TYPE                DATA   AGE
demo-app-secret   Opaque              1      12m
demo-app-tls      kubernetes.io/tls   3      14m

$ kubectl -n demo-dev describe sealedsecret demo-app-secret-typo | grep -A6 Status
Status:
  Conditions:
    Last Transition Time:  2026-11-24T19:39:10Z
    Last Update Time:      2026-11-24T19:39:10Z
    Message:               no key could decrypt secret (APP_SECRET)
    Status:                False
    Type:                  Synced
  Observed Generation:     1
Events:

$ kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=2
time=2026-11-24T19:39:10.537Z level=ERROR msg="Error updating, giving up" key=demo-dev/demo-app-secret-typo error="no key could decrypt secret (APP_SECRET)"
E1124 19:39:10.537453       1 controller.go:390] "Unhandled Error" err="no key could decrypt secret (APP_SECRET)" logger="UnhandledError"
$ tras el arreglo
NAME                            READY   STATUS    RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running   0          12m
NAME           SYNC STATUS   HEALTH STATUS
demo-app-dev   Synced        Healthy

```

**Causa raíz:** (1) el Deployment referencia un Secret que no existe; (2) Sealed Secrets cifra con
el *scope* `strict` por defecto: el texto cifrado está ligado a nombre **y** namespace, así que
fuera de su destino ningún par de claves lo descifra (`no key could decrypt secret`).

**Arreglo:** corregir el nombre en `app-values.yaml`, borrar el `SealedSecret` inválido; el pod
nuevo arranca y reemplaza al anterior.

**Prevención:** no copiar SealedSecrets entre entornos: resellar con `scripts/seal-secret.sh`
para cada namespace; ordenar los recursos con *sync waves* (el secreto antes que la app); alerta
sobre `SealedSecret` con condición `Synced=False`.

---

## Incidente 5 — Ingress roto

**Cambio provocado:** `ingress.className: nginx-typo` en dev.

**Síntomas:** `curl` devuelve `404 Not Found` de nginx (el *default backend*); el certificado TLS
sigue siendo válido (`ssl_verify=0`) y los pods están sanos: **la app no ha caído, está
inalcanzable**.

**Diagnóstico:**

```text
$ curl https://app-dev.local:9443/ (Ingress con ingressClassName inexistente)
http=404 ssl_verify=0
<html>
<head><title>404 Not Found</title></head>
<body>

$ kubectl -n demo-dev get ingress
NAME           CLASS        HOSTS           ADDRESS        PORTS     AGE
demo-app-dev   nginx-typo   app-dev.local   10.96.154.98   80, 443   15m

$ kubectl get ingressclass
NAME              CONTROLLER             PARAMETERS   AGE
nginx (default)   k8s.io/ingress-nginx   <none>       15m

$ kubectl -n demo-dev describe ingress demo-app-dev | grep -E 'Class|Events' -A3
Ingress Class:    nginx-typo
Default backend:  <default>
TLS:
--
Events:
  Type    Reason             Age                  From                       Message
  ----    ------             ----                 ----                       -------

$ kubectl -n demo-dev get certificate
NAME           READY   SECRET         AGE
demo-app-tls   True    demo-app-tls   14m

$ kubectl -n demo-dev get pods (la app sigue sana)
NAME                            READY   STATUS    RESTARTS   AGE
demo-app-dev-6965859569-g8pzf   1/1     Running   0          12m
$ curl tras restaurar el Ingress
{"message": "Hola desde dev", "version": "v1.0.0", "hostname": "demo-app-dev-6965859569-g8pzf", "secret_configured": true}

http=200
NAME           CLASS   HOSTS           ADDRESS        PORTS     AGE
demo-app-dev   nginx   app-dev.local   10.96.154.98   80, 443   15m

```

**Causa raíz:** el controlador ingress-nginx solo atiende los Ingress de su `IngressClass`
(`nginx`); un Ingress con una clase inexistente se ignora, y nginx responde con su 404 por defecto.
El `Certificate` sí se emitió (cert-manager no depende de la clase del controlador).

**Arreglo:** quitar el override de `className` y sincronizar; `curl` vuelve a `200`.

**Prevención:** prueba de humo tras cada sync (`curl` al host con la CA local); alerta sobre
`probe_success` con blackbox-exporter; `ingressClassResource.default: true` (ya activo) no salva
a un Ingress con una clase explícita equivocada, así que mejor no sobrescribir la clase por entorno.

---

## Incidente 6 — Deriva manual y *self-heal* de Argo CD

**Cambio provocado:** en el cluster, a mano, `kubectl scale deploy demo-app-dev --replicas=4` y
`kubectl delete svc demo-app-dev` (la aplicación tiene `syncPolicy.automated.selfHeal: true`).

**Síntomas:** durante ≈1 s Argo CD marca `OutOfSync/Progressing`; enseguida el Deployment vuelve
a `replicas: 1` y el Service se recrea.

**Diagnóstico:**

```text
$ kubectl -n demo-dev scale deploy demo-app-dev --replicas=4   (drift manual)
deployment.apps/demo-app-dev scaled
20:41:12.239 replicas(spec)=4 argocd=demo-app-dev OutOfSync Progressing
20:41:13.185 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:14.111 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:15.057 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:16.011 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:16.961 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:17.921 replicas(spec)=1 argocd=demo-app-dev Synced Healthy
20:41:18.873 replicas(spec)=1 argocd=demo-app-dev Synced Healthy

$ kubectl -n demo-dev get events --sort-by=.lastTimestamp | grep -i scal | tail -4
3m26s       Normal    ScalingReplicaSet    deployment/demo-app-dev              Scaled up replica set demo-app-dev-656474bc4b from 0 to 1
2m48s       Normal    ScalingReplicaSet    deployment/demo-app-dev              Scaled down replica set demo-app-dev-656474bc4b from 1 to 0
7s          Normal    ScalingReplicaSet    deployment/demo-app-dev              (combined from similar events): Scaled up replica set demo-app-dev-6965859569 from 1 to 4
7s          Normal    ScalingReplicaSet    deployment/demo-app-dev              Scaled down replica set demo-app-dev-6965859569 from 4 to 1

$ kubectl -n demo-dev get deploy demo-app-dev -o jsonpath='{.metadata.managedFields[*].manager}'
argocd-controller kube-controller-manager


$ kubectl -n demo-dev delete svc demo-app-dev   (borrado manual; 12 s después)
service "demo-app-dev" deleted from demo-dev namespace
NAME           TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
demo-app-dev   ClusterIP   10.96.137.62   <none>        80/TCP    12s

```

**Causa raíz:** Argo CD compara continuamente el estado vivo con Git; con `selfHeal` revierte
cualquier cambio manual (el `managedFields` muestra a `argocd-controller` reescribiendo el
Deployment).

**Arreglo:** no hace falta; el cambio duradero se hace en Git. Si de verdad hay que escalar a mano
en una emergencia, hay que desactivar `selfHeal` temporalmente o usar un HPA fuera del control de Argo.

**Prevención:** Git como única fuente de verdad, permisos RBAC de solo lectura para `kubectl` en
prod y revisión por PR. Ojo con el HPA: si se escala el Deployment con un HPA hay que quitar
`replicas` del manifiesto o ignorar esa diferencia (`ignoreDifferences`).

---

## Notas honestas

- Las capturas del incidente 1 muestran `403 Forbidden` del registro, no un `manifest unknown`: es lo
  que responde GHCR para una etiqueta/repositorio inexistente o privado.
- El incidente 3 documenta dos modos de fallo distintos (`StartError` con 4Mi y `OOMKilled` con 12Mi)
  porque se probaron los dos; lo realista en producción es el segundo.
- La alerta del incidente 3 que aparece en Alertmanager corresponde al primer pod fallido (4Mi): las
  alertas tardan un ciclo de evaluación en reflejar el pod nuevo.
- No se probó un pod `OOMKilled` en tiempo de ejecución por carga (solo por límite bajo en el arranque).
