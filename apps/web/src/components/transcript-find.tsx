import { useEffect, useRef } from 'react'
import { ShidouIcon } from '@/components/shidou-icon'
import { cn } from '@/lib/utils'

type Translator = (key: string, params?: Record<string, string | number>) => string

export function TranscriptFindBar({
  query,
  current,
  total,
  limited,
  t,
  onQueryChange,
  onNavigate,
  onClose,
}: {
  query: string
  current: number | null
  total: number
  limited: boolean
  t: Translator
  onQueryChange: (query: string) => void
  onNavigate: (backward: boolean) => void
  onClose: () => void
}) {
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const element = input.current
    if (!element) return
    element.focus()
    element.select()
  }, [])

  const hasMatches = total > 0
  const countLabel = !query
    ? null
    : hasMatches
      ? t('find.result_count', {
          current: current === null ? 0 : current + 1,
          total: `${total}${limited ? '+' : ''}`,
        })
      : t('find.no_results')

  return (
    <div
      className="absolute right-3 top-2 z-20 flex w-[min(430px,calc(100%-24px))] min-w-[260px] items-center gap-1.5 rounded-lg border border-input bg-[var(--raised)] p-1.5 shadow-sm"
      data-transcript-search-skip
      role="search"
    >
      <input
        aria-label={t('input.find')}
        autoComplete="off"
        className="h-6 min-w-0 flex-1 bg-transparent px-1 text-[13px] outline-none placeholder:text-[var(--text-ghost)]"
        placeholder={t('input.find')}
        ref={input}
        spellCheck={false}
        type="text"
        value={query}
        onChange={(event) => onQueryChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault()
            onNavigate(event.shiftKey)
          } else if (event.key === 'Escape') {
            event.preventDefault()
            onClose()
          } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f') {
            event.preventDefault()
            input.current?.select()
          }
        }}
      />
      {countLabel && (
        <span
          aria-live="polite"
          className="shrink-0 whitespace-nowrap text-[11.5px] tabular-nums text-[var(--text-tertiary)]"
        >
          {countLabel}
        </span>
      )}
      <FindBarButton
        disabled={!hasMatches}
        icon="arrowUp"
        label={t('find.previous_match')}
        onClick={() => onNavigate(true)}
      />
      <FindBarButton
        disabled={!hasMatches}
        icon="arrowDown"
        label={t('find.next_match')}
        onClick={() => onNavigate(false)}
      />
      <FindBarButton icon="x" label={t('find.close')} onClick={onClose} />
    </div>
  )
}

function FindBarButton({
  icon,
  label,
  disabled = false,
  onClick,
}: {
  icon: 'arrowUp' | 'arrowDown' | 'x'
  label: string
  disabled?: boolean
  onClick: () => void
}) {
  return (
    <button
      aria-label={label}
      className={cn(
        'grid size-6 shrink-0 place-items-center rounded-md text-[var(--text-secondary)] outline-none hover:bg-accent focus-visible:ring-1 focus-visible:ring-ring',
        disabled && 'opacity-45 hover:bg-transparent',
      )}
      disabled={disabled}
      title={label}
      type="button"
      onClick={onClick}
    >
      <ShidouIcon className="size-3.5" name={icon} />
    </button>
  )
}
