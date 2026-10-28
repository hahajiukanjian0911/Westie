// 内核接口探针：验证原生 App 依赖的链路在当前内核版本上仍然可用。
// 只调只读或幂等的方法，绝不发 prompt。
// 用法：node scripts/probe.mjs "<dsh web: 打印的地址>"
const startUrl = new URL(process.argv[2])
const origin = startUrl.origin
const token = startUrl.searchParams.get('token')

const results = []
const check = (name, ok, detail = '') => {
  results.push({ name, ok })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`)
}

// 1. API 接入：/connect 换 cookie
const connect = await fetch(`${origin}/connect?token=${token}&interactions=answer`, { redirect: 'manual' })
const cookie = (connect.headers.get('set-cookie') ?? '').split(';')[0]
check('connect', connect.status === 302 && cookie.startsWith('dsh-auth-'), `HTTP ${connect.status}`)

// 2. 生命周期 socket：$events 流首帧必须是 ready
const ws = new WebSocket(`${origin.replace('http', 'ws')}/api/remote.mux`, { headers: { cookie } })
const streams = new Map()
ws.onmessage = (e) => {
  const msg = JSON.parse(String(e.data))
  streams.get(msg.streamId)?.(msg)
}
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })

const openStream = (endpoint, args) => new Promise((resolve) => {
  const streamId = `s${streams.size + 1}`
  const timer = setTimeout(() => resolve({ type: 'timeout' }), 5000)
  streams.set(streamId, (msg) => { clearTimeout(timer); resolve(msg) })
  ws.send(JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }))
})

const ready = await openStream('$events', {})
check('$events ready', ready.type === 'item' && ready.value?.type === 'ready', `home=${ready.value?.host?.home}`)

// 3. 一元调用
const call = async (endpoint, args) => {
  const res = await fetch(`${origin}/api/${endpoint}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: crypto.randomUUID(), method: endpoint, payload: { args } }),
  })
  return (await res.json()).result
}

const list = await call('session/list', { _request: {} })
check('session/list', list?.ok === true, `${list?.value?.items?.length ?? '?'} 个会话`)

const catalog = await call('session/modelCatalog', {})
check('session/modelCatalog', catalog?.ok === true, `默认 ${catalog?.value?.default?.provider}/${catalog?.value?.default?.model}`)

// 4. 流式调用
const follow = await openStream('workspace/follow', {})
check('workspace/follow baseline', follow.type === 'item' && follow.value?.type === 'baseline',
  `${follow.value?.value?.items?.length ?? '?'} 个工作区`)

ws.close()
const failed = results.filter((r) => !r.ok).length
console.log(failed === 0 ? `\n全部 ${results.length} 项通过` : `\n${failed} 项失败`)
process.exit(failed === 0 ? 0 : 1)
