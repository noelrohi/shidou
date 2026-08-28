import { describe, expect, test } from 'bun:test'
import { PROTOCOL_VERSION } from '@shidou/client/protocol'
import { webProtocolVersion } from './protocol-version'

describe('Web wire protocol selection', () => {
  test('local development follows the checkout-built daemon', () => {
    expect(webProtocolVersion(true)).toBe(PROTOCOL_VERSION)
  })

  test('production keeps the released-daemon pin', () => {
    expect(webProtocolVersion(false)).toBeUndefined()
  })
})
