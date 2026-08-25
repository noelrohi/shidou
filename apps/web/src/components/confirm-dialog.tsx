import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog'
import { ShidouIcon, type ShidouIconName } from '@/components/shidou-icon'
import { useI18n } from '@/lib/i18n'

/**
 * Window-modal confirmation for an action that cannot be undone.
 *
 * The destructive control takes focus on open, so Return confirms and Escape
 * dismisses the way the desktop dialogs bind them. `children` carries whatever
 * detail the caller wants under the body — a list of what is at stake, say.
 */
export function ConfirmDialog({
  open,
  icon = 'trash',
  title,
  body,
  confirmLabel,
  returnFocus,
  children,
  onConfirm,
  onOpenChange,
}: {
  open: boolean
  icon?: ShidouIconName
  title: string
  body: string
  confirmLabel: string
  returnFocus?: RefObject<HTMLElement | null>
  children?: ReactNode
  onConfirm: () => void | Promise<void>
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useI18n()
  const [pending, setPending] = useState(false)
  const confirmButton = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (open) setPending(false)
  }, [open])

  async function confirm() {
    if (pending) return
    setPending(true)
    try {
      await onConfirm()
      onOpenChange(false)
    } catch {
      // The caller reports the failure; staying open lets the user retry.
      setPending(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => { if (!next && !pending) onOpenChange(false) }}>
      <DialogContent
        className="max-w-[380px] rounded-[18px] bg-[var(--raised)] p-[18px]"
        finalFocus={returnFocus}
        initialFocus={confirmButton}
        onKeyDown={(event) => {
          // The focused control answers Return first, the way the desktop
          // dialog's buttons do, so Return on Cancel still cancels. This only
          // catches Return from the surface itself.
          if (event.key !== 'Enter' || pending) return
          if (event.target instanceof HTMLElement && event.target.closest('button')) return
          event.preventDefault()
          void confirm()
        }}
      >
        <DialogTitle className="flex items-center gap-[9px] text-[14.5px] font-medium">
          <ShidouIcon className="size-[15px] shrink-0 text-destructive" name={icon} />
          {/* Unlike any list rows below, the title is not truncated: clipping
              it would drop the closing quote and question mark and leave the
              sentence reading as a fragment. */}
          <span className="min-w-0">{title}</span>
        </DialogTitle>
        <p className="mt-2.5 text-[13px] leading-[18px] text-[var(--text-secondary)]">{body}</p>
        {children}
        <div className="mt-3.5 flex items-center justify-end gap-2">
          <Button
            disabled={pending}
            size="sm"
            variant="outline"
            onClick={() => onOpenChange(false)}
          >
            {t('common.cancel')}
          </Button>
          <Button
            disabled={pending}
            ref={confirmButton}
            size="sm"
            variant="destructive"
            onClick={() => void confirm()}
          >
            {confirmLabel}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}

/** The short list of what is at stake, as prose rows rather than a filled panel. */
export function ConfirmDialogDetails({ lines }: { lines: string[] }) {
  if (!lines.length) return null
  return (
    <ul className="mt-2.5 flex flex-col gap-1.5 text-[13px] leading-[17px] text-[var(--text-secondary)]">
      {lines.map((line) => (
        <li className="flex items-center gap-2" key={line}>
          <span aria-hidden className="size-[3px] shrink-0 rounded-full bg-[var(--text-ghost)]" />
          <span className="min-w-0 truncate">{line}</span>
        </li>
      ))}
    </ul>
  )
}
