# Decisiones

## kind en lugar de k3s
k3s se instala con script de sistema y necesita `sudo`. kind solo necesita Docker y permite varios
nodos (`bootstrap/kind-config.yaml`: 1 control-plane y 2 workers), que es lo más parecido a un cluster real
sin privilegios. Contrapartida: el rendimiento y la red no son representativos de producción.

## Dos repositorios (app y plataforma)
El repo de la app contiene el código, el Dockerfile y el chart; este repo contiene **qué** se despliega
y **dónde**. Así los cambios de configuración y las promociones no mezclan historia con el código y se
pueden revisar por PR de forma independiente. Argo CD usa *multi-source*: el chart sale del repo de la app
y los valores del entorno (`envs/*/app-values.yaml`) de este.

## App-of-apps
`bootstrap/root-app.yaml` es lo único que se aplica a mano; apunta a `apps/`, donde hay una `Application`
por componente. Añadir un componente es añadir un fichero y hacer push. Se usan *sync waves* para que los
CRD (cert-manager, Prometheus) existan antes de los recursos que los usan, con `retry` como red de seguridad.

## Helm values por entorno (y Kustomize para lo propio)
Las aplicaciones de terceros y la app demo se configuran con valores Helm porque es el formato de sus
charts. Lo que escribimos nosotros a mano (issuers, reglas, secretos) usa Kustomize: es plano, se valida
con `kubectl kustomize` y no requiere plantillas.
Dev sigue `main` del repo de la app y prod se fija a la etiqueta `v1.0.0` (promoción explícita).

## cert-manager con CA local
Un `ClusterIssuer` autofirmado crea una CA propia y esa CA firma los certificados de los Ingress
(`local-ca`). Es lo más cercano a un emisor real (ACME/Let's Encrypt) que se puede hacer sin dominio ni
Internet entrante. No es de confianza para nadie fuera de este laboratorio; para probar, `curl --cacert`.

## Sealed Secrets
Los secretos se cifran con la clave pública del cluster y el YAML cifrado va a Git (`platform/secrets/`).
Se eligió el *scope* `strict` (por defecto): un SealedSecret solo sirve para su nombre y namespace
(se demuestra en el incidente 4). La clave privada se queda fuera de Git (`.secrets/`, ignorada) y
`bootstrap.sh` la restaura si existe; así un cluster recreado puede descifrar lo ya commiteado.

## kube-prometheus-stack
Se desactiva Grafana (ahorro de memoria) y los componentes del plano de control que en kind no exponen
métricas, para no tener alertas falsas. Prometheus recoge `ServiceMonitor` y `PrometheusRule` de cualquier
namespace (`*SelectorNilUsesHelmValues: false`). Las alertas propias cubren los fallos más habituales de
una aplicación: sin réplicas disponibles, pod no listo y `OOMKilled`.

## Imagen cargada con `kind load`
El paquete de GHCR es privado al crearse; la publicación sí funciona desde el CI, pero para que el cluster
local no dependa de credenciales o de cambiar visibilidad a mano, se construye la imagen en local y se
carga en los nodos. `imagePullPolicy: IfNotPresent` hace el resto.

## Sin *prune* manual ni cambios en el cluster
`syncPolicy.automated` con `prune` y `selfHeal` en todas las aplicaciones: Git manda, y cualquier cambio
manual se revierte en segundos (incidente 6).

## Qué no se hizo y por qué
- Notificaciones de Alertmanager: requieren un servicio externo (cuenta, token).
- Argo CD sin Ingress propio: se accede con `kubectl port-forward` para no abrir más superficie.
- Políticas de red y Kyverno/OPA: fuera del alcance de este laboratorio.
