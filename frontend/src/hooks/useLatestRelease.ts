import { useEffect, useState } from 'react'

interface ReleaseInfo {
  version: string
  url: string
}

let cache: ReleaseInfo | null | 'error' | 'pending' = null

/**
 * Drop a SemVer pre-release/build suffix so a locally tagged build compares
 * equal to the upstream release it is based on: this fork ships `3.4.1-luu`
 * off upstream's `3.4.1` and must not report itself as perpetually outdated.
 * A genuinely newer upstream release still differs in its base version.
 */
function baseVersion(version: string): string {
  return version.split(/[-+]/)[0]
}

export function useLatestRelease(currentVersion: string) {
  const [latest, setLatest] = useState<ReleaseInfo | null>(
    cache && cache !== 'error' && cache !== 'pending' ? cache : null,
  )

  useEffect(() => {
    if (cache !== null) return
    cache = 'pending'
    fetch('https://api.github.com/repos/Pouzor/homelable/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
    })
      .then((res) => {
        if (!res.ok) { cache = 'error'; return }
        return res.json()
      })
      .then((data) => {
        if (!data || typeof data.tag_name !== 'string' || !data.html_url) {
          cache = 'error'
          return
        }
        const version = data.tag_name.replace(/^v/, '')
        const info: ReleaseInfo = { version, url: data.html_url }
        cache = info
        setLatest(info)
      })
      .catch(() => {
        cache = 'error'
      })
  }, [])

  const hasUpdate =
    latest !== null && baseVersion(latest.version) !== baseVersion(currentVersion)
  return { latest, hasUpdate }
}
