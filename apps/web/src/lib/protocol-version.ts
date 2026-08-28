import { PROTOCOL_VERSION } from '@shidou/client/protocol'

/**
 * Production stays on the released-daemon wire pin. Local Vite development
 * follows the generated checkout protocol used by the debug daemon.
 */
export function webProtocolVersion(development: boolean): number | undefined {
  return development ? PROTOCOL_VERSION : undefined
}
