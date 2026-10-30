#!/usr/bin/env python3
"""Usage: python3 scripts/perf/summarize.py temp/perf/runs/<timestamp>
Groups the same operation/page across independent launches; never pools pages or
individual tokens as repeated runs. JSON keeps all samples, median, worst and n.
Layout quietness has a >=60ms observation floor. CPU=one full core at 100%.
"""
import json, pathlib, statistics, sys
from collections import defaultdict
root=pathlib.Path(sys.argv[1]).resolve()
groups=defaultdict(list)

def add(key,value):
    if value is not None: groups[key].append(value)

for directory in sorted(root.iterdir()):
    log=directory/'perf.jsonl'
    if not log.exists() or directory.name=='seed': continue
    rows=[json.loads(l) for l in log.read_text().splitlines() if l]
    phase={r['name']:r for r in rows}
    name=directory.name
    # Strip the repeat number but retain the cold/warm split.
    scenario='-'.join(p for p in name.split('-') if not p.isdigit())
    if name.startswith('startup'):
        launch=json.loads((directory/'launch.json').read_text())
        for event in ['app_init','kernel_ready','connect_ready','app_ready','window_layout_ready']:
            if event in phase and launch.get('process_wall'):
                add(f'{scenario}/process_to_{event}.ms',(phase[event]['wall']-launch['process_wall'])*1000)
        for start,end,label in [('kernel_start','kernel_ready','kernel'),('profile_start','profile_ready','profile'),('node_spawn','kernel_ready','node'),('connect_start','connect_http_ready','connect_http'),('connect_start','connect_ready','connect'),('app_ready','window_layout_ready','ready_to_layout')]:
            if start in phase and end in phase: add(f'{scenario}/{label}.ms',(phase[end]['uptime']-phase[start]['uptime'])*1000)
    select=next((r for r in rows if r['name']=='step_begin_select'),None)
    snapshot=next((r for r in rows if select and r['name']=='follow_snapshot' and r['uptime']>select['uptime']),None)
    if snapshot: add(f'{scenario}/select_to_snapshot.ms',(snapshot['uptime']-select['uptime'])*1000)
    if scenario=='sidebar':
        prompt=next((r for r in rows if r['name']=='step_begin_prompt'),None)
        refresh=next((r for r in rows if prompt and r['name']=='session_list' and r['uptime']>prompt['uptime']),None)
        if refresh: add(f'{scenario}/message_to_refresh.ms',(refresh['uptime']-prompt['uptime'])*1000)
        query=next((r for r in rows if r['name']=='step_begin_sidebarquery'),None)
        content=next((r for r in rows if query and r['name']=='sidebar_content_results' and r['uptime']>query['uptime']),None)
        if content:
            add(f'{scenario}/first_query_to_content.ms',(content['uptime']-query['uptime'])*1000)
            last_query=max((r for r in rows if r['name']=='step_begin_sidebarquery' and r['uptime']<content['uptime']),key=lambda r:r['uptime'])
            add(f'{scenario}/last_query_to_content.ms',(content['uptime']-last_query['uptime'])*1000)
    occurrence=defaultdict(int)
    for row in rows:
        event=row['name']
        if event in ['earlier_model','session_list','step_select','step_process','step_scroll','step_sidebarquery','step_refresh','step_prompt','step_idle']:
            occurrence[event]+=1; event+=f'_{occurrence[event]}'
        elif not (event.startswith('interval_') or event.startswith('history_page_') or event in ['history_complete','fixture_check','startup']):
            continue
        for metric,value in row.items():
            if metric not in ['wall','uptime','name'] and isinstance(value,(int,float)):
                add(f'{scenario}/{event}.{metric}',value)
        if row.get('text_deltas',0)>0:
            if row.get('ms',0)>0:
                add(f'{scenario}/{event}.deltas_per_sec',row['text_deltas']/(row['ms']/1000))
                add(f'{scenario}/{event}.chars_per_sec',row.get('text_chars',0)/(row['ms']/1000))
            for metric in ['markdown_parse','markdown_body_stream','conversation_body','hosting_update','conversation_content_body','conversation_history_body','conversation_block_body','history_anchor_resolve','hosting_root_replace','markdown_timeline']:
                add(f'{scenario}/{event}.{metric}_per_delta',row.get(metric,0)/row['text_deltas'])
    add(f'{scenario}/observed_rss_max.mb',max((r.get('rss_mb',0) for r in rows),default=0))
summary={k:{'n':len(v),'median':statistics.median(v),
    'worst':min(v) if k.endswith(('.text_deltas','.text_chars','.deltas_per_sec','.chars_per_sec')) else max(v),
    'min':min(v),'max':max(v),'samples':v} for k,v in sorted(groups.items())}
(root/'summary.json').write_text(json.dumps(summary,indent=2))
lines=['# Westie performance samples','', '| Metric | n | Median | Worst |','|---|---:|---:|---:|']
for key,value in summary.items():
    lines.append(f"| {key} | {value['n']} | {value['median']:.3f} | {value['worst']:.3f} |")
(root/'summary.md').write_text('\n'.join(lines)+'\n')
print(root/'summary.json')
