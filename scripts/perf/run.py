#!/usr/bin/env python3
"""Westie background performance baseline, stdlib only (macOS, Node 24, Xcode).
Usage: python3 scripts/perf/run.py [all|startup|history|stream|sidebar|seed] [--repeat 3] [--sample]
Build once: xcodegen generate && xcodebuild -scheme Westie -derivedDataPath temp/DerivedData build
No HID/AX, activation, cache purges, real model or user-data access. New timestamped
runs never overwrite old evidence. Only fresh temp/perf homes are used; mock is
loopback-only, API keys scrubbed. Cold = fresh home/profile, NOT OS-cache cold.
Stream uses a >=4k-character response and a requested 20s live window (actual
wall time may overrun when main is busy); the isolated app exits mid-response.
--sample retains one 3s macOS sample per measured scenario; affects that run.
"""
import argparse, ctypes, datetime, fcntl, hashlib, json, os, pathlib, shutil, socket, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
PERF = ROOT / 'temp/perf'
APP = ROOT / 'temp/DerivedData/Build/Products/Debug/Westie.app'
NODE = pathlib.Path.home() / '.local/share/mise/installs/node/24/bin/node'
ENV = {k:v for k,v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith('WESTIE_') and k != 'DSH_HOME'}

def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2))

def blank(home):
    ws = PERF / 'fixtures/workspace'
    ws.mkdir(parents=True, exist_ok=True)
    (ws/'README.md').write_text('Westie synthetic performance workspace.\n')
    stamp = '2026-10-30T00:00:00.000Z'
    dump(home/'storages/workspace.json', {'unit':{'name':'workspace','version':2},'global':{'initialized':True,'workspaceIds':['perf-workspace'],'archivedSessionIds':[],'pinnedSessionIds':[]},'tables':{'workspaces':{'perf-workspace':{'path':str(ws),'title':'Perf Fixture','sessionIds':[],'createdAt':stamp,'updatedAt':stamp}}}})

def records(path):
    # A log may be observed between write() and its terminating newline.
    text=path.read_text()
    return [json.loads(l) for l in text.splitlines() if l] if text.endswith('\n') else [json.loads(l) for l in text.splitlines()[:-1] if l]

def run_app(directory, home, script, port, sample=False, timeout=600):
    directory.mkdir(parents=True, exist_ok=False)
    config = directory/'config'
    config.mkdir()
    # Resolve existing ancestors, reject symlinks escaping the exclusive perf root.
    for path in (directory, home, config):
        if not path.resolve().is_relative_to(PERF.resolve()):
            raise ValueError('performance path escaped temp/perf')
    values = {'WESTIE_MOCK_LLM':str(port),'WESTIE_DSH_HOME':str(home), 'WESTIE_CONFIG_HOME':str(config),
        'WESTIE_PERF_LOG':str(directory/'perf.jsonl'),'WESTIE_PERF_KERNEL_LOG':str(directory/'kernel.log'),
        'WESTIE_AUTOMATION_LOG':str(directory/'automation.log'),'WESTIE_AUTOMATION':script,'WESTIE_NODE':str(NODE)}
    command = ['open','-g','-j','-n']
    for key,value in values.items(): command += ['--env',f'{key}={value}']
    before = time.time()
    subprocess.run(command+[str(APP)],env=ENV,check=True)
    sampler = None
    pid = None
    completed = False
    try:
        while time.time()-before < timeout:
            log = directory/'perf.jsonl'
            data = records(log) if log.exists() else []
            if data and pid is None:
                pid = int(data[0]['pid'])
                # libproc gives actual process birth time, separate from open request.
                class BSDInfo(ctypes.Structure):
                    _fields_ = [('prefix',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),('suffix',ctypes.c_uint32*5),('nice',ctypes.c_int32),('startsec',ctypes.c_uint64),('startusec',ctypes.c_uint64)]
                info=BSDInfo(); lib=ctypes.CDLL('/usr/lib/libproc.dylib')
                n=lib.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))
                dump(directory/'launch.json',{'open_wall':before,'pid':pid,'process_wall':info.startsec+info.startusec/1e6 if n==ctypes.sizeof(info) else None})
            text = (directory/'automation.log').read_text() if (directory/'automation.log').exists() else ''
            if sample and sampler is None and pid and any(r['name'].startswith('interval_begin_') or r['name']=='step_begin_perfhistory' for r in data):
                sampler = subprocess.Popen(['/usr/bin/sample',str(pid),'3','1','-file',str(directory/'sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if '\n' in text and ' quit\n' in text:
                for _ in range(600):
                    try: os.kill(pid,0)
                    except ProcessLookupError: break
                    time.sleep(.1)
                else: raise RuntimeError(f'app did not exit: {directory}')
                node_pid = next((int(r['pid']) for r in data if r['name'] == 'node_started'), None)
                if node_pid is not None:
                    for _ in range(60):
                        try: os.kill(node_pid, 0)
                        except ProcessLookupError: break
                        time.sleep(.1)
                    else: raise RuntimeError(f'kernel remained after app exit: {directory}')
                if sampler: sampler.wait()
                if 'FAIL' in text or 'REFUSED' in text: raise RuntimeError(f'automation failed: {directory}')
                completed = True
                return data
            time.sleep(.1)
        # Only the pid from this run is eligible for cleanup; normal TERM first.
        if pid: os.kill(pid,15)
        raise TimeoutError(str(directory))
    finally:
        if not completed and pid:
            try: os.kill(pid,15)
            except ProcessLookupError: pass
        if sampler and sampler.poll() is None:
            sampler.terminate()
            sampler.wait(timeout=5)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenario',nargs='?',default='all',choices=['all','startup','history','stream','sidebar','seed'])
    parser.add_argument('--repeat',type=int,default=3)
    parser.add_argument('--sample',action='store_true')
    args=parser.parse_args()
    if args.repeat < 1: parser.error('--repeat must be positive')
    if PERF.resolve() != PERF:
        raise ValueError('temp/perf (or an ancestor) must not be a symlink')
    PERF.mkdir(parents=True,exist_ok=True)
    lock=(PERF/'measurement.lock').open('a')
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('another performance run owns temp/perf')
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    output=PERF/'runs'/stamp
    output.mkdir(parents=True)
    dump(output/'environment.json',{'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'system':subprocess.check_output(['sw_vers'],text=True),'machine':subprocess.check_output(['uname','-m'],text=True),'repeat':args.repeat,'scenario':args.scenario,'sample':args.sample})
    sources=sorted((ROOT/'App/Westie').rglob('*.swift'))+sorted((ROOT/'Packages/WestieKit/Sources').rglob('*.swift'))+[ROOT/'scripts/mock-llm.mjs']
    sources += [APP/'Contents/MacOS/Westie',APP/'Contents/MacOS/Westie.debug.dylib']
    sources += [ROOT/'scripts/perf/run.py', ROOT/'scripts/perf/summarize.py']
    dump(output/'source-sha256.json',{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    mocklog=(output/'mock.log').open('w')
    mock=subprocess.Popen([str(NODE),str(ROOT/'scripts/mock-llm.mjs'),str(port)],env=ENV,stdout=mocklog,stderr=mocklog)
    try:
        for _ in range(50):
            with socket.socket() as sock:
                if sock.connect_ex(('127.0.0.1',port))==0: break
            time.sleep(.1)
        else: raise RuntimeError('mock did not start')
        if args.scenario=='seed':
            home=output/'seed-home'; blank(home)
            run_app(output/'seed',home,'new;prompt:/steps;idle:90;prompt:/md;idle:90;dump;quit',port)
            print(output,flush=True); return
        fixture=PERF/'fixtures/home'
        if not (fixture/'storages/workspace.json').exists():
            seed=output/'seed-home'; blank(seed)
            run_app(output/'seed',seed,'new;prompt:/steps;idle:90;prompt:/md;idle:90;dump;quit',port)
            subprocess.run([str(NODE),str(ROOT/'scripts/perf/fixtures.mjs'),str(seed)],check=True)
        for repeat in range(1,args.repeat+1):
            for scenario in (['startup','history','stream-short','stream-long','sidebar'] if args.scenario=='all' else (['stream-short','stream-long'] if args.scenario=='stream' else [args.scenario])):
                name=f'{scenario}-{repeat}'
                home=output/(name+'-home')
                if scenario=='startup':
                    blank(home)
                    script='wait:0.4;quit'
                    run_app(output/(name+'-cold'),home,script,port)
                    run_app(output/(name+'-warm'),home,script,port)
                else:
                    shutil.copytree(fixture,home)
                    if scenario=='history':
                        script='fixturecheck:400;select:perf-long;perfhistory;perfbegin:history-interact;scroll:10000;process:0;process:0;scroll:200000;perfend:history-interact;quit'
                    elif scenario.startswith('stream'):
                        script='fixturecheck:400;select:'+('perf-long;perfhistory;' if scenario.endswith('long') else 'perf-short;')+'perfbegin:'+scenario+';prompt:/perfmd slow;wait:20;perfend:live;quit'
                    else:
                        script='fixturecheck:400;perfbegin:sidebar-interact;sidebarquery:P;sidebarquery:Pe;sidebarquery:Perf 1;wait:0.6;sidebarquery:;refresh;select:perf-short;prompt:sidebar refresh;idle:90;wait:1;perfend:sidebar-interact;quit'
                    run_app(output/name,home,script,port,sample=args.sample)
                print(name,flush=True)
        subprocess.run(['python3',str(ROOT/'scripts/perf/summarize.py'),str(output)],check=True)
        print(output,flush=True)
    finally:
        mock.terminate();mock.wait(timeout=5);mocklog.close()

if __name__=='__main__': main()
