#!/usr/bin/env node
// Usage: Node 24 scripts/perf/fixtures.mjs <isolated-seed-home>
// Seed is produced by run.py using /steps then /md on the loopback mock.
// Writes a NEW home under temp/perf/fixtures; refuses replacement of evidence.
// Storage format 4, real native events, 150 turns + 399 small sessions (60 children).
import { readFileSync, writeFileSync, mkdirSync, globSync, existsSync, realpathSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { constants, zstdCompressSync } from 'node:zlib'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const perf = join(root, 'temp/perf')
const seed = realpathSync(resolve(process.argv[2]))
if (!seed.startsWith(realpathSync(perf) + '/')) throw Error('seed must be inside temp/perf')
const output = join(perf, 'fixtures/home')
if (existsSync(output)) throw Error('fixture exists: preserve it; move to a new location before regenerating')
const [path] = globSync(join(seed, 'sessions/*/*/session.v4.jsonl.zstd'))
if (!path) throw Error('missing seed')
// DSH appends independent zstd frames. Node 24's decoder stops after frame one;
// use the existing Homebrew zstd CLI (BSD-3-Clause) to decode every append batch.
const records = execFileSync('zstd',['-dc',path],{maxBuffer:32*1024*1024}).toString().trim().split('\n').map(JSON.parse)
const [catalogPath] = globSync(join(root,'kernel/node_modules/.pnpm/@deepseek-ai+dsh-session-format-catalog@0.2.1-rc.3*/node_modules/@deepseek-ai/dsh-session-format-catalog/lib/index.js'))
const { sessionFormatCatalog } = await import(catalogPath)
const header = records[0]
const firstEnd = records.findIndex(r => r.type === 'turn/end')
const first = records.slice(1,firstEnd+1)
const second = records.slice(firstEnd+1)
if (second.at(-1)?.type !== 'turn/end') throw Error('incomplete seed')
const workspace = header.cwd
const projectSegment = '--' + workspace.slice(1).replaceAll('/','-') + '--'
const baseTime = 1793318400000
const ids = ['perf-long', 'perf-short', ...Array.from({length:398},(_,i)=>`perf-${String(i).padStart(3,'0')}`)]
const allowed = r => !['session-log-deepseek/delivery-accepted','session/title-llm-request','job/registered','job/settled'].includes(r.type)
let longItems = 0
for (const [index,id] of ids.entries()) {
  const meta = {...header,id,createdAt:baseTime+index*1000}
  if(index>=340) { meta.origin='subagent'; meta.parentSession=ids[2+(index-340)%40]; meta.delegationDepth=1 }
  const all=[]
  const rounds = index===0?150:1
  for(let turn=1;turn<=rounds;turn++) {
    const template = (turn===1 || (index===0 && turn%3===0) ? first : second).filter(allowed).filter(r => turn===1 || !['system/message','permission/preset','sandbox/mode','approval/policy'].includes(r.type))
    const offset=all.length
    const seqMap=new Map(template.map((r,i)=>[r.seq,offset+i]))
    const names=new Map()
    function rewrite(value,key='') {
      if(Array.isArray(value)) return value.map(v=>rewrite(v,key))
      if(value&&typeof value==='object') return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,rewrite(v,k)]))
      if(['id','callId','toolCallId','rpcId','jobId'].includes(key)&&typeof value==='string') {
        if(!names.has(value)) names.set(value,`${value}-${id}-t${turn}`)
        return names.get(value)
      }
      if(key==='sessionId') return id
      if(key==='turn') return turn
      if(['messageSeqs','throughSeq','sourceEventSeqs'].includes(key)&&typeof value==='number') return seqMap.get(value)??0
      return value
    }
    for(const [i,record] of template.entries()) {
      const r=rewrite(record)
      r.seq=offset+i; r.time=meta.createdAt+turn*10000+i*10
      if(r.type==='session/title') r.data.title=`Perf ${index} synthetic`
      if(r.type==='user/message'&&r.data.source?.kind==='user') {
        r.data.content=[{type:'text',text:`Perf ${index} turn ${turn}: synthetic Markdown/tool workload`}]
      }
      all.push(r)
    }
  }
  // Title sourced from a genuine user message; stable fallback event avoids model title requests.
  const user=all.find(r=>r.type==='user/message'&&r.data.source?.kind==='user')
  all.push({type:'session/title',seq:all.length,time:all.at(-1).time+1,data:{title:`Perf ${index} synthetic`,messageSeqs:[user.seq],source:{kind:'fallback'}}})
  if(index===0) longItems=all.filter(r=>r.type==='user/message'||r.type==='assistant/message').length
  // Fail closed on schema/lifecycle/seq/tool ownership errors before measuring the app.
  const restore = sessionFormatCatalog.createRestore(meta,{validation:'current'})
  for(const event of all) restore.decodeRow(event)
  restore.finish()
  const dir=join(output,'sessions',projectSegment,id)
  mkdirSync(dir,{recursive:true})
  const pack = text => zstdCompressSync(Buffer.from(text),{params:{[constants.ZSTD_c_checksumFlag]:1}})
  writeFileSync(join(dir,'session.v4.jsonl.zstd'),Buffer.concat([pack(JSON.stringify(meta)+'\n'),pack(all.map(JSON.stringify).join('\n')+'\n')]))
}
const store=JSON.parse(readFileSync(join(seed,'storages/workspace.json')))
const w=Object.values(store.tables.workspaces)[0]
w.sessionIds=ids.filter((_,i)=>i<340)
store.global.archivedSessionIds=ids.slice(280,320)
store.global.pinnedSessionIds=ids.slice(2,12)
mkdirSync(join(output,'storages'),{recursive:true})
writeFileSync(join(output,'storages/workspace.json'),JSON.stringify(store,null,2))
writeFileSync(join(perf,'fixtures/manifest.json'),JSON.stringify({seed:path,format:4,sessions:400,children:60,pinned:10,archived:40,longTurns:150,longMessageEvents:longItems,workspace},null,2))
console.log(output)
