import { describe, expect, test } from 'bun:test'
import { normalizeDaemonAddress, validateConnectionConfig } from './connection'

describe('normalizeDaemonAddress', () => {
  test('normalizes host, HTTP, and daemon paths', () => {
    expect(normalizeDaemonAddress('host.example:34123')).toBe(
      'ws://host.example:34123',
    )
    expect(normalizeDaemonAddress('https://shidou.example/v1?token=nope')).toBe(
      'wss://shidou.example',
    )
    expect(normalizeDaemonAddress('HTTP://SHIDOU.EXAMPLE/v1')).toBe(
      'ws://shidou.example',
    )
  })

  test('rejects unsupported schemes and credentials', () => {
    expect(() => normalizeDaemonAddress('ftp://shidou.example')).toThrow()
    expect(() => normalizeDaemonAddress('ws://token@shidou.example')).toThrow()
  })

  test('requires a token without putting it in the address', () => {
    expect(() =>
      validateConnectionConfig({ address: 'shidou.example', token: '  ' }),
    ).toThrow('token')
    expect(
      validateConnectionConfig({ address: 'shidou.example', token: 'secret' }),
    ).toEqual({
      address: 'ws://shidou.example',
      token: 'secret',
      remember: false,
    })
  })
})
