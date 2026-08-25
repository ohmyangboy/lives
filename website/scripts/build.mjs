import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const source = resolve(root, 'src')
const output = resolve(root, 'dist')
const version = process.env.LIVES_VERSION || '0.1.4-beta.1'
const downloadUrl = process.env.LIVES_DOWNLOAD_URL || 'https://github.com/ohmyangboy/lives/releases/latest'

await rm(output, { recursive: true, force: true })
await mkdir(output, { recursive: true })
await cp(source, output, { recursive: true })

const htmlFiles = (await readdir(output)).filter((name) => name.endsWith('.html'))
await Promise.all(htmlFiles.map(async (name) => {
  const htmlPath = resolve(output, name)
  const html = await readFile(htmlPath, 'utf8')
  await writeFile(
    htmlPath,
    html
      .replaceAll('__LIVES_VERSION__', version)
      .replaceAll('__LIVES_DOWNLOAD_URL__', downloadUrl),
  )
}))

console.log(`Lives website built: v${version} → ${output}`)
