// 导出内核 Remote 方法的描述符（参数、结果的 JSON Schema），用于对照编写 Swift 模型。
// 用法：node scripts/dump-remote.mjs <方法名…>   不给方法名则列出全部方法
import { readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
const root = new URL('../kernel/node_modules/.pnpm/', import.meta.url).pathname
const wanted = process.argv.slice(2)
const methods = {}
for (const dir of readdirSync(root).filter((d) => d.startsWith('@deepseek-ai+'))) {
  const scope = join(root, dir, 'node_modules', '@deepseek-ai')
  for (const pkg of readdirSync(scope)) {
    const file = join(scope, pkg, 'lib', 'typert.remote-client.js')
    if (!existsSync(file)) continue
    const { TYPERT_REMOTE } = await import(pathToFileURL(file).href)
    for (const [name, m] of Object.entries(TYPERT_REMOTE.methods)) methods[name] ??= { package: pkg, ...m }
  }
}
if (wanted.length === 0) { for (const n of Object.keys(methods).sort()) console.log(n); process.exit(0) }
const strip = (v) => JSON.parse(JSON.stringify(v, (k, x) => (k === 'codec' ? undefined : x)))
for (const n of wanted) console.log(JSON.stringify({ [n]: strip(methods[n]) }, null, 1))
