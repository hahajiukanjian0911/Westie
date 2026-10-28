// 本地假模型：兼容 Anthropic Messages 流式协议，内核通过 DEEPSEEK_BASE_URL 指向它。
// 让测试能真正发 prompt、看流式输出，却不触达任何真实模型，也不会让 Agent 执行工具。
// 用法：node scripts/mock-llm.mjs [端口]   每个请求记一行到 stderr
import { createServer } from 'node:http'

const port = Number(process.argv[2] ?? 3190)

// 最后一条 user 消息：真实输入是第一个文本块，后面跟着内核追加的运行时上下文块。
const lastUser = (body) => [...(body.messages ?? [])].reverse().find((m) => m.role === 'user')
const blocks = (message) => (typeof message?.content === 'string' ? [{ type: 'text', text: message.content }] : message?.content ?? [])
const userText = (body) => blocks(lastUser(body)).find((b) => b.type === 'text')?.text?.trim() ?? ''

// 暗号触发工具调用，用来测试工具、审批、提问界面；命令都是无害的 echo。
const TOOL_SCRIPTS = {
  '/bash': { name: 'bash', input: { description: '打印测试文本', command: 'echo westie-mock-tool' } },
  '/approve': {
    name: 'bash',
    input: { description: '需要审批的测试命令', command: 'echo approved-by-user', sandbox_permissions: 'danger-full-access', justification: 'Westie 审批界面测试' },
  },
  '/ask': {
    name: 'ask_user_question',
    input: { questions: [{ id: 'color', header: '选择', question: '测试提问：你喜欢哪个颜色？', options: [{ label: '蓝色', description: '冷静' }, { label: '橙色', description: '温暖' }] }] },
  },
}

// `/md`：覆盖常见 Markdown 语法，用来核对渲染。
const MARKDOWN_SAMPLE = [
  '## 二级标题',
  '',
  '正文里有**加粗**、*斜体*、~~删除线~~、`行内代码`和[链接](https://example.com)。第二句话写长一点，看看换行之后的行距是否舒服，以及中英文 mixed text 的排版。',
  '',
  '### 三级标题',
  '',
  '- 无序列表第一项',
  '- 第二项',
  '  - 嵌套的子项',
  '- 第三项',
  '',
  '1. 有序列表',
  '2. 第二步',
  '3. 第三步',
  '',
  '> 这是一段引用，用来放提示或摘录。',
  '',
  '| 名称 | 类型 | 说明 |',
  '| --- | --- | --- |',
  '| path | String | 文件路径 |',
  '| force | Bool | 是否覆盖 |',
  '',
  '```swift',
  '// 注释',
  'let count = 42',
  'func greet(_ name: String) -> String {',
  '    return "hello \\(name)"',
  '}',
  '```',
  '',
  '---',
  '',
  '最后一段。',
].join('\n')

const plan = (body) => {
  // 辅助请求（会话标题）：短答复。
  if ((body.max_tokens ?? 0) <= 200 || !body.tools) return { text: '模拟会话' }
  // 上一步是工具结果：收尾。
  if (blocks(lastUser(body)).some((b) => b.type === 'tool_result')) return { text: '工具调用完成，这是假模型的收尾回复。' }
  const text = userText(body)
  const script = Object.entries(TOOL_SCRIPTS).find(([cue]) => text.startsWith(cue))?.[1]
  if (script) return { text: '我来调用一个工具。', tool: script }
  if (text.startsWith('/md')) return { text: MARKDOWN_SAMPLE }
  return { text: `这是来自本地假模型的回复。\n\n你说的是：「${text.slice(0, 200)}」\n\n- 第一点\n- 第二点\n\n\`\`\`swift\nprint("hello westie")\n\`\`\`` }
}

const server = createServer(async (req, res) => {
  let raw = ''
  for await (const chunk of req) raw += chunk
  const body = raw ? JSON.parse(raw) : {}
  console.error(`${new Date().toISOString()} ${req.method} ${req.url} model=${body.model} stream=${body.stream}`)
  if (!req.url.endsWith('/v1/messages')) { res.writeHead(404).end(); return }

  if (process.env.MOCK_TOOLS_DUMP && body.tools) {
    const { writeFileSync } = await import('node:fs')
    writeFileSync(process.env.MOCK_TOOLS_DUMP, JSON.stringify(body.tools, null, 1))
  }
  const { text, tool } = plan(body)
  const usage = { input_tokens: 42, output_tokens: text.length, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
  const id = `msg_mock_${Date.now()}`
  if (!body.stream) {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ id, type: 'message', role: 'assistant', model: body.model, content: [{ type: 'text', text }], stop_reason: 'end_turn', stop_sequence: null, usage }))
    return
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`)
  const pause = (ms) => new Promise((r) => setTimeout(r, ms))
  send('message_start', { message: { id, type: 'message', role: 'assistant', model: body.model, content: [], stop_reason: null, stop_sequence: null, usage: { ...usage, output_tokens: 0 } } })
  let index = 0
  if (body.thinking?.type === 'enabled' || body.thinking?.type === 'adaptive') {
    send('content_block_start', { index, content_block: { type: 'thinking', thinking: '', signature: '' } })
    for (const piece of ['先想一想', '……', '好了。']) { send('content_block_delta', { index, delta: { type: 'thinking_delta', thinking: piece } }); await pause(60) }
    send('content_block_delta', { index, delta: { type: 'signature_delta', signature: 'mock' } })
    send('content_block_stop', { index })
    index += 1
  }
  send('content_block_start', { index, content_block: { type: 'text', text: '' } })
  for (const piece of text.match(/[\s\S]{1,6}/g)) { send('content_block_delta', { index, delta: { type: 'text_delta', text: piece } }); await pause(25) }
  send('content_block_stop', { index })
  if (tool) {
    index += 1
    send('content_block_start', { index, content_block: { type: 'tool_use', id: `toolu_mock_${Date.now()}`, name: tool.name, input: {} } })
    send('content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(tool.input) } })
    send('content_block_stop', { index })
  }
  send('message_delta', { delta: { stop_reason: tool ? 'tool_use' : 'end_turn', stop_sequence: null }, usage })
  send('message_stop', {})
  res.end()
})

server.listen(port, '127.0.0.1', () => console.error(`mock-llm listening on http://127.0.0.1:${port}`))
