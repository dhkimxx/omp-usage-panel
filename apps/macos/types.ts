export interface ExternalSource { providerId: string; path: string }
export interface PanelConfig {
  version: 1
  nodePath: string
  ompPath: string
  profile: string
  refreshSeconds: number
  cacheMinutes: number
  timeoutSeconds: number
  providers: string[] | null
  labels: Record<string, string>
  metrics: Record<string, string>
  warnPercent: number
  criticalPercent: number
  showPace: boolean
  externalSources: ExternalSource[]
}
