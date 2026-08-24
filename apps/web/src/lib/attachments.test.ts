import { describe, expect, test } from 'bun:test'
import type { ShidouClient } from '@shidou/client'
import { importDaemonPathAttachment, importDaemonPathAttachments } from './attachments'

describe('importDaemonPathAttachment', () => {
  test('asks the daemon to import an absolute path without sending file bytes', async () => {
    let command: unknown
    const client = {
      request: async (next: unknown) => {
        command = next
        return {
          type: 'attachmentStored',
          attachment: {
            reference: 'shidou-attachment:one',
            path: '/home/me/.shidou/attachments/one/logo.png',
            name: 'logo.png',
            isDir: false,
          },
        }
      },
    } as unknown as ShidouClient

    const attachment = await importDaemonPathAttachment(client, '/Users/me/Pictures/logo.png')

    expect(command).toEqual({
      type: 'importPathAttachment',
      path: '/Users/me/Pictures/logo.png',
    })
    expect(attachment).toEqual({
      path: '/home/me/.shidou/attachments/one/logo.png',
      mention: '/Users/me/Pictures/logo.png',
      name: 'logo.png',
      is_dir: false,
      is_image: true,
      blob_reference: 'shidou-attachment:one',
    })
  })
})

describe('importDaemonPathAttachments', () => {
  test('imports a batch in one request and keeps failed slots as null', async () => {
    let command: unknown
    const client = {
      request: async (next: unknown) => {
        command = next
        return {
          type: 'attachmentsStored',
          attachments: [
            {
              reference: 'shidou-attachment:one',
              path: '/home/me/.shidou/attachments/one/logo.png',
              name: 'logo.png',
              isDir: false,
            },
            null,
          ],
        }
      },
    } as unknown as ShidouClient

    const attachments = await importDaemonPathAttachments(client, [
      '/Users/me/Pictures/logo.png',
      '/Users/me/Pictures/missing.png',
    ])

    expect(command).toEqual({
      type: 'importPathAttachments',
      paths: ['/Users/me/Pictures/logo.png', '/Users/me/Pictures/missing.png'],
    })
    expect(attachments).toEqual([
      {
        path: '/home/me/.shidou/attachments/one/logo.png',
        mention: '/Users/me/Pictures/logo.png',
        name: 'logo.png',
        is_dir: false,
        is_image: true,
        blob_reference: 'shidou-attachment:one',
      },
      null,
    ])
  })
})
