{{/*
Common name helpers
*/}}
{{- define "cart-iq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cart-iq.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cart-iq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "cart-iq.labels" -}}
helm.sh/chart: {{ include "cart-iq.chart" . }}
app.kubernetes.io/name: {{ include "cart-iq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: cart-iq
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels — for matchLabels and Service selectors. Component is appended by callers.
*/}}
{{- define "cart-iq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cart-iq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Domain helpers — auto-derive when blank.
*/}}
{{- define "cart-iq.domain" -}}
{{- required "global.domain is required" .Values.global.domain -}}
{{- end -}}

{{- define "cart-iq.publicUrl" -}}
{{- printf "https://%s" (include "cart-iq.domain" .) -}}
{{- end -}}

{{/*
Image references — auto-derive ECR path when repository is blank.
*/}}
{{- define "cart-iq.image.backend" -}}
{{- $repo := .Values.image.backend.repository -}}
{{- if not $repo -}}
{{- $repo = printf "%s.dkr.ecr.%s.amazonaws.com/cart-iq/backend" (required "global.awsAccountId is required" .Values.global.awsAccountId) (required "global.awsRegion is required" .Values.global.awsRegion) -}}
{{- end -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.backend.tag) -}}
{{- end -}}

{{- define "cart-iq.image.web" -}}
{{- $repo := .Values.image.web.repository -}}
{{- if not $repo -}}
{{- $repo = printf "%s.dkr.ecr.%s.amazonaws.com/cart-iq/web" .Values.global.awsAccountId .Values.global.awsRegion -}}
{{- end -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.web.tag) -}}
{{- end -}}

{{- define "cart-iq.image.scraper" -}}
{{- $repo := .Values.image.scraper.repository -}}
{{- if not $repo -}}
{{- $repo = printf "%s.dkr.ecr.%s.amazonaws.com/cart-iq/scraper" .Values.global.awsAccountId .Values.global.awsRegion -}}
{{- end -}}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.scraper.tag) -}}
{{- end -}}

{{- define "cart-iq.image.auth" -}}
{{- printf "%s:%s" .Values.image.auth.repository .Values.image.auth.tag -}}
{{- end -}}

{{/*
Service account names
*/}}
{{- define "cart-iq.sa.backend" -}}
{{- printf "%s-backend" (include "cart-iq.fullname" .) -}}
{{- end -}}

{{- define "cart-iq.sa.celery" -}}
{{- printf "%s-celery" (include "cart-iq.fullname" .) -}}
{{- end -}}

{{/*
Secret names — same names whether ESO or inline secrets are used,
so Deployment templates are agnostic.
*/}}
{{- define "cart-iq.secretName.backend" -}}{{ printf "%s-backend" (include "cart-iq.fullname" .) }}{{- end -}}
{{- define "cart-iq.secretName.db" -}}{{ printf "%s-db" (include "cart-iq.fullname" .) }}{{- end -}}
{{- define "cart-iq.secretName.redis" -}}{{ printf "%s-redis" (include "cart-iq.fullname" .) }}{{- end -}}
{{- define "cart-iq.secretName.auth" -}}{{ printf "%s-auth" (include "cart-iq.fullname" .) }}{{- end -}}
{{- define "cart-iq.secretName.llm" -}}{{ printf "%s-llm" (include "cart-iq.fullname" .) }}{{- end -}}
{{- define "cart-iq.configMapName" -}}{{ printf "%s-config" (include "cart-iq.fullname" .) }}{{- end -}}

{{/*
envFrom block for backend/celery/migrate — references all 5 secrets + configmap.
*/}}
{{- define "cart-iq.backendEnvFrom" -}}
- configMapRef:
    name: {{ include "cart-iq.configMapName" . }}
- secretRef:
    name: {{ include "cart-iq.secretName.backend" . }}
- secretRef:
    name: {{ include "cart-iq.secretName.db" . }}
- secretRef:
    name: {{ include "cart-iq.secretName.redis" . }}
- secretRef:
    name: {{ include "cart-iq.secretName.llm" . }}
{{- end -}}

{{/*
Derived env vars injected into backend (computed from values, not in configmap).
*/}}
{{- define "cart-iq.backendDerivedEnv" -}}
- name: ALLOWED_HOSTS
  value: {{ default (printf "%s,localhost,127.0.0.1,%s-backend" (include "cart-iq.domain" .) (include "cart-iq.fullname" .)) .Values.config.ALLOWED_HOSTS | quote }}
- name: CSRF_TRUSTED_ORIGINS
  value: {{ default (include "cart-iq.publicUrl" .) .Values.config.CSRF_TRUSTED_ORIGINS | quote }}
- name: HOST_NAME
  value: {{ default (include "cart-iq.publicUrl" .) .Values.config.HOST_NAME | quote }}
- name: BETTER_AUTH_URL
  value: {{ default (printf "%s/auth" (include "cart-iq.publicUrl" .)) .Values.backend.betterAuthUrl | quote }}
- name: AWS_REGION
  value: {{ default .Values.global.awsRegion .Values.config.AWS_REGION | quote }}
- name: SCRIPT_NAME
  value: "/service-api"
{{- end -}}

{{/*
envFrom block for web — needs only configmap; URLs come from derived env.
*/}}
{{- define "cart-iq.webEnv" -}}
- name: NODE_ENV
  value: "production"
- name: NUXT_PUBLIC_API_BASE_URL
  value: {{ default (printf "%s/service-api" (include "cart-iq.domain" .)) .Values.web.publicApiBaseUrl | quote }}
- name: NUXT_PUBLIC_AUTH_BASE_URL
  value: {{ default (printf "%s/auth/api/auth" (include "cart-iq.publicUrl" .)) .Values.web.publicAuthBaseUrl | quote }}
- name: NUXT_PUBLIC_APP_BASE_URL
  value: {{ default (include "cart-iq.publicUrl" .) .Values.web.publicAppBaseUrl | quote }}
- name: NUXT_PUBLIC_API_SCHEME
  value: {{ .Values.web.publicApiScheme | quote }}
- name: NUXT_PUBLIC_ENABLED_SOCIAL_PROVIDERS
  value: {{ .Values.web.enabledSocialProviders | quote }}
- name: NUXT_PUBLIC_SCRAPER_DEFAULT_PINCODE
  value: {{ .Values.web.scraperDefaultPincode | quote }}
{{- end -}}

{{/*
envFrom block for auth.
*/}}
{{- define "cart-iq.authEnvFrom" -}}
- secretRef:
    name: {{ include "cart-iq.secretName.auth" . }}
- secretRef:
    name: {{ include "cart-iq.secretName.db" . }}
{{- end -}}

{{- define "cart-iq.authDerivedEnv" -}}
- name: PORT
  value: {{ .Values.auth.appPort | quote }}
- name: BASE_DOMAIN
  value: {{ default (include "cart-iq.domain" .) .Values.auth.baseDomain | quote }}
- name: BASE_PATH
  value: {{ .Values.auth.basePath | quote }}
- name: BETTER_AUTH_URL
  value: {{ default (printf "%s/auth" (include "cart-iq.publicUrl" .)) .Values.auth.betterAuthUrl | quote }}
- name: WEBHOOK_EP
  value: {{ default (printf "http://%s-backend:%v/service-api/api/auth/webhook/" (include "cart-iq.fullname" .) .Values.backend.containerPort) .Values.auth.webhookEndpoint | quote }}
- name: TRUSTED_ORIGINS
  value: {{ default (include "cart-iq.publicUrl" .) .Values.auth.trustedOrigins | quote }}
- name: REQUIRE_EMAIL_VERIFICATION
  value: {{ .Values.auth.requireEmailVerification | quote }}
- name: DATABASE_STRING
  valueFrom:
    secretKeyRef:
      name: {{ include "cart-iq.secretName.db" . }}
      key: DATABASE_STRING_AUTH
{{- end -}}

{{/*
Pod security context — applied to every pod.
*/}}
{{- define "cart-iq.podSecurityContext" -}}
runAsNonRoot: {{ .Values.podSecurity.runAsNonRoot }}
runAsUser: {{ .Values.podSecurity.runAsUser }}
fsGroup: {{ .Values.podSecurity.fsGroup }}
seccompProfile:
  type: {{ .Values.podSecurity.seccompProfile.type }}
{{- end -}}

{{/*
Container security context.
*/}}
{{- define "cart-iq.containerSecurityContext" -}}
allowPrivilegeEscalation: {{ .Values.podSecurity.allowPrivilegeEscalation }}
readOnlyRootFilesystem: {{ .Values.podSecurity.readOnlyRootFilesystem }}
runAsNonRoot: {{ .Values.podSecurity.runAsNonRoot }}
runAsUser: {{ .Values.podSecurity.runAsUser }}
capabilities:
  drop: {{ .Values.podSecurity.capabilities.drop | toJson }}
{{- end -}}

{{/*
Topology spread block (used by backend/web/auth).
*/}}
{{- define "cart-iq.topologySpread" -}}
{{- if .Values.topologySpread.enabled -}}
- maxSkew: {{ .Values.topologySpread.maxSkew }}
  topologyKey: {{ .Values.topologySpread.topologyKey }}
  whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
  labelSelector:
    matchLabels:
      {{- include "cart-iq.selectorLabels" . | nindent 6 }}
{{- end -}}
{{- end -}}

{{/*
Init container that blocks until the named Secret exists in the namespace.
Used by pre-install Jobs (auth-db-init, migrate) so they don't race ESO's first
reconcile of the `db` ExternalSecret. The image is small (kubectl static binary),
and the celery SA has a narrow Role granting `get` on this Secret only.
*/}}
{{- define "cart-iq.waitForSecret" -}}
- name: wait-for-secret
  image: {{ .Values.preInstallWait.image | default "bitnami/kubectl:1.30" | quote }}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      SECRET={{ include "cart-iq.secretName.db" . }}
      DEADLINE=$(( $(date +%s) + {{ .Values.preInstallWait.timeoutSeconds | default 120 }} ))
      until kubectl -n {{ .Release.Namespace }} get secret "$SECRET" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "Timed out waiting for Secret/$SECRET to be reconciled by ESO" >&2
          exit 1
        fi
        echo "Waiting for Secret/$SECRET ..."
        sleep 3
      done
      echo "Secret/$SECRET is ready"
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }
  securityContext:
    {{- include "cart-iq.containerSecurityContext" . | nindent 4 }}
{{- end -}}
