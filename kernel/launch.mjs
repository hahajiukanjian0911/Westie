// Westie 内核启动壳：原样转发参数给 dsh 启动器，并在父进程（Westie.app）消失时让内核正常退出。
// macOS 没有 PDEATHSIG，App 崩溃或被强退时，靠这里避免内核变成孤儿进程。
const parent = process.ppid
setInterval(() => {
  if (process.ppid !== parent) process.kill(process.pid, 'SIGTERM')
}, 1000).unref()

const { runCli } = await import('./node_modules/@deepseek-ai/dsh/lib/bin.js')
await runCli()
