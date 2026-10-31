"""Loopback-only SSH fixture. Never connects to a real cluster.

Run with a scratch directory. Integration tests consume connection.json and
generated throwaway keys; no credentials or keys are checked into the project.
Requires Python 3.10+ and paramiko (`python -m pip install paramiko`).
"""
import base64
import hashlib
import io
import json
import logging
import os
import posixpath
import socket
import stat as stat_mode
import shlex
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import paramiko
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding, PrivateFormat, NoEncryption, BestAvailableEncryption,
)

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
host = paramiko.RSAKey.generate(2048)
rsa = paramiko.RSAKey.generate(2048)
rsa.write_private_key_file(str(root / "rsa.pem"))
rsa.write_private_key_file(str(root / "rsa-encrypted.pem"), password="fixture-passphrase")
ed = Ed25519PrivateKey.generate()
for name, encryption in (("ed25519", NoEncryption()), ("ed25519-encrypted", BestAvailableEncryption(b"fixture-passphrase"))):
    (root / name).write_bytes(ed.private_bytes(Encoding.PEM, PrivateFormat.OpenSSH, encryption))
ed_key = paramiko.Ed25519Key.from_private_key(io.StringIO((root / "ed25519").read_text()))
allowed = {rsa.asbytes(), ed_key.asbytes()}
lock = threading.Lock()
counters = {"connections": 0, "password_auth": 0, "key_auth": 0, "commands": 0,
            "sftp_reads": 0, "sftp_writes": 0, "sftp_sessions": 0,
            "exec_commands": 0, "submissions": 0, "node_attempts": 0,
            "capacity_queries": 0, "output_searches": 0, "sftp_listings": 0,
            "exec_requests": 0, "channel_requests": 0}
(root / "counters.json").write_text(json.dumps(counters))

def count(key, persist=True):
    with lock:
        counters[key] += 1
        if not persist: return
        scratch = root / 'counters-next.json'
        scratch.write_text(json.dumps(counters))
        for attempt in range(20):
            try:
                scratch.replace(root / 'counters.json')
                break
            except PermissionError:
                if attempt == 19: raise
                time.sleep(0.005)

def output(include_capacity=True):
    settings = json.loads((root / "state.json").read_text()) if (root / "state.json").exists() else {}
    state = settings.get("state", "RUNNING")
    queue_status = 1 if settings.get("queueError") else 0
    job_id = str(settings.get("jobId", "42"))
    terminal = state not in ("PENDING", "RUNNING")
    end = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") if terminal else "Unknown"
    ids = [str(int(job_id) + i) for i in range(max(1, min(20, int(settings.get("count", 1)))))]
    queue = "" if terminal else "\n".join(f"{jid}|fixture-job|compute|{state}|00:10:00|01:00:00|8|4G|cn01|None|1|2026-10-24T01:00:00|{jid}|/home/tester/project-{jid}" for jid in ids)
    stats = "\n".join(
        f"{jid}.batch|00:{5 * (i % 3 + 1):02}:00|{i % 3 + 1}G|{i % 3 + 1}G|4"
        for i, jid in enumerate(ids)
    )
    accounting = "\n".join(f"{jid}|fixture-job|compute|{state}|00:10:00|8|4Gc||0:0|1|cn01|{end}|2026-10-24T01:00:00|None|01:00:00|/home/tester/project-{jid}" for jid in ids)
    capacity = """===NODES===
NodeName=cn01 RealMemory=262144
NodeName=cn02 RealMemory=262144
===STATUS:NODES:0===
""" if include_capacity else ""
    return f"""===META===
{int(time.time())}
===SQUEUE===
{queue}
===STATUS:SQUEUE:{queue_status}===
===SSTAT===
{stats}
===STATUS:SSTAT:0===
===SACCT===
{accounting}
===STATUS:SACCT:0===
===SINFO===
compute*|up|cn01|mixed|8/56/0/64
compute*|up|cn02|idle|0/64/0/64
===STATUS:SINFO:0===
{capacity}
""".encode()

# In-memory test files only: SFTP has no access to the host filesystem.
test_files = {
    'job.sh': b'#!/bin/bash\n#SBATCH --job-name=fixture\n#SBATCH --time=00:01:00\nprintf "fixture only\\n"\n',
    'POSCAR.fixed': b'Fixed-atom example\n1.0\n6 0 0\n0 6 0\n0 0 6\nSi\n3\nSelective dynamics\nDirect\n.2 .2 .2 F F F\n.7 .2 .2 T F T\n.5 .7 .4 T T T\n',
    'CONTCAR.fixed': b'Fixed-atom example\n1.0\n6 0 0\n0 6 0\n0 0 6\nSi\n3\nSelective dynamics\nDirect\n.2 .2 .2 F F F\n.7 .2 .2 T F T\n.5 .7 .4 T T T\n',
    'POSCAR': b'Silicon\n1.0\n5.43 0 0\n0 5.43 0\n0 0 5.43\nSi\n2\nDirect\n0 0 0\n.25 .25 .25\n',
    'CONTCAR': b'Silicon relaxed\n1.0\n5.42 0 0\n0 5.42 0\n0 0 5.42\nSi\n2\nDirect\n0 0 0\n.25 .25 .25\n',
    'water.gjf': b'# B3LYP/6-31G(d) opt\n\nWater\n\n0 1\nO 0 0 0\nH .758 0 .504\nH -.758 0 .504\n\n',
    'silicon.cif': b'data_Si\n_cell_length_a 5.43\n_cell_length_b 5.43\n_cell_length_c 5.43\n_cell_angle_alpha 90\n_cell_angle_beta 90\n_cell_angle_gamma 90\nloop_\n_space_group_symop_operation_xyz\n\'x,y,z\'\n\'-x,-y,-z\'\nloop_\n_atom_site_type_symbol\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nSi .125 .125 .125\n',
    'slurm-42.out': b'Starting calculation...\nElectronic convergence reached\nIonic step 12 completed\nJob running\n',
    "a 'quoted' $(file).txt": b'Literal filename, no shell evaluation.\n',
    'large.log': b'FIRST LINE\n' + b'calculation step\n' * 140000 + b'LAST LINE\n',
    'binary.bin': b'\x00\x01\x02not text',
    'outputs/result.txt': b'Energy = -100.123 eV\n',
}

# A complete OUTCAR larger than the text-preview limit. The last force block
# is intentionally unfinished, as can happen while VASP is writing the file.
outcar_lines = ['NIONS = 2', ' direct lattice vectors', '5.43 0 0', '0 5.43 0', '0 0 5.43']
oszicar_lines = []
for step in range(1, 13):
    outcar_lines += ['POSITION TOTAL-FORCE (eV/Angst)', '------------------',
                    f'0 0 0 {0.4 / step} {0.12 / step} 0',
                    f'1 1 1 {-0.2 / step} 0 0', '------------------',
                    f'energy without entropy = -100 energy(sigma->0) = {-108.5 + 1 / step}']
    oszicar_lines.append(f' {step if step <= 8 else step-8} F= -108.5 E0= {-108.5 + 1 / step} d E = -0.01')
    if step == 6:
        outcar_lines += ['irrelevant electronic output ' + 'x' * 120] * 20000
outcar_lines += ['POSITION TOTAL-FORCE (eV/Angst)', '------------------', '0 0 0 0.001 0 0']
test_files['OUTCAR'] = ('\n'.join(outcar_lines) + '\n').encode()
test_files['OSZICAR'] = ('\n'.join(oszicar_lines) + '\n').encode()
for serial_index in range(70):
    serial_dir = f'serial/run-{serial_index:02}/stage/relax/ionic'
    test_files[f'{serial_dir}/OUTCAR'] = (
        'vasp.6.3\nIBRION = 2\n' +
        '\n'.join(f'energy(sigma->0) = {-100 + 1 / step}' for step in range(1, 13)) + '\n'
    ).encode()
    test_files[f'{serial_dir}/OSZICAR'] = (
        '\n'.join(f' {step} F= -100 E0= {-100 + 1 / step}' for step in range(1, 13)) + '\n'
    ).encode()
test_files['water.log'] = (
    'Entering Gaussian System\n' + 'irrelevant electronic output\n' * 90000 +
    'Standard orientation:\n-----\n'
    'Center Atomic Atomic Coordinates (Angstroms)\nNumber Number Type X Y Z\n-----\n'
    '1 8 0 0 0 0\n2 1 0 .758 0 .504\n3 1 0 -.758 0 .504\n-----\n'
    'SCF Done: E(RB3LYP) = -76.123456789 A.U.\n'
    'Item Value Threshold Converged?\n'
    'Maximum Force .0045 .00045 NO\nRMS Force .0002 .0003 YES\n'
    'Maximum Displacement .018 .0018 NO\nRMS Displacement .00012 .0012 YES\n'
).encode()

def file_key(path):
    path = posixpath.normpath(path)
    for jid in range(42, 62):
        prefix = f'/home/tester/project-{jid}/'
        if path.startswith(prefix):
            return path[len(prefix):]
        if path == prefix[:-1]:
            return ''
    return None

def output_mtime(name):
    if name.startswith('serial/run-'):
        return 1792807201 + int(name.split('/')[1].split('-')[1])
    return 1792807200

def attrs(name, content=None, directory=False, link=False):
    attr = paramiko.SFTPAttributes()
    attr.filename = name
    attr.st_mode = (stat_mode.S_IFLNK if link else stat_mode.S_IFDIR if directory else stat_mode.S_IFREG) | 0o444
    attr.st_size = len(content) if content else 0
    attr.st_mtime = attr.st_atime = 1792807200
    return attr

class ReadHandle(paramiko.SFTPHandle):
    def __init__(self, content):
        super().__init__(os.O_RDONLY)
        self.content = content

    def read(self, offset, length):
        count('sftp_reads', persist=False)
        return self.content[offset:offset + length]

    def stat(self):
        return attrs('', self.content)

class ReadOnlyFiles(paramiko.SFTPServerInterface):
    def session_ended(self):
        count('sftp_sessions')

    def list_folder(self, path):
        count('sftp_listings')
        key = file_key(path)
        if key is None: return paramiko.SFTP_NO_SUCH_FILE
        prefix = key.rstrip('/') + '/' if key else ''
        children = {}
        for filename, content in test_files.items():
            if not filename.startswith(prefix): continue
            relative = filename[len(prefix):]
            name = relative.split('/')[0]
            if '/' in relative:
                children[name] = attrs(name, directory=True)
            else:
                entry = attrs(name, content)
                entry.st_mtime = entry.st_atime = output_mtime(filename)
                children[name] = entry
        if key == '':
            children['results-link'] = attrs('results-link', directory=True, link=True)
            children['private.txt'] = attrs('private.txt')
        return list(children.values()) if children else paramiko.SFTP_NO_SUCH_FILE

    def stat(self, path):
        key = file_key(path)
        if key in ('', 'outputs', 'results-link'): return attrs('', directory=True)
        if key is not None and any(name.startswith(key.rstrip('/') + '/') for name in test_files):
            return attrs('', directory=True)
        if key == 'private.txt': return paramiko.SFTP_PERMISSION_DENIED
        if key in test_files:
            entry = attrs('', test_files[key])
            entry.st_mtime = entry.st_atime = output_mtime(key)
            return entry
        return paramiko.SFTP_NO_SUCH_FILE

    def lstat(self, path):
        if file_key(path) == 'results-link': return attrs('', link=True)
        return self.stat(path)

    def open(self, path, flags, attr):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            count('sftp_writes')
            return paramiko.SFTP_PERMISSION_DENIED
        key = file_key(path)
        if key == 'private.txt': return paramiko.SFTP_PERMISSION_DENIED
        if key in test_files: return ReadHandle(test_files[key])
        return paramiko.SFTP_NO_SUCH_FILE

class Fixture(paramiko.ServerInterface):
    def get_allowed_auths(self, username):
        return "publickey,password"

    def check_auth_password(self, username, password):
        count("password_auth")
        return paramiko.AUTH_SUCCESSFUL if username == "tester" and password == "fixture-password" else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        count("key_auth")
        return paramiko.AUTH_SUCCESSFUL if username == "tester" and key.asbytes() in allowed else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        count('channel_requests')
        settings = json.loads((root / 'state.json').read_text()) if (root / 'state.json').exists() else {}
        time.sleep(min(float(settings.get('channelOpenDelay', 0)), 17))
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        count('node_attempts')
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        if not command.startswith(b"bash -lc "):
            return False
        is_command = b'SLURM_DIRECTORY_COMMAND_V1' in command
        is_search = b'SLURM_OUTPUT_SEARCH_V2' in command
        if b'squeue --array -u ' not in command and not is_command and not is_search:
            return False
        count("commands")
        count('exec_requests')
        settings = json.loads((root / 'state.json').read_text()) if (root / 'state.json').exists() else {}
        time.sleep(min(float(settings.get('execAckDelay', 0)), 17))
        def respond():
            try:
                time.sleep(0.02)
                code = 0
                if is_search:
                    count('output_searches')
                    settings = json.loads((root / 'state.json').read_text()) if (root / 'state.json').exists() else {}
                    time.sleep(min(float(settings.get('searchDelay', 0)), 3))
                    script = shlex.split(command.decode())[2]
                    directory = shlex.split(script.splitlines()[2])[2]
                    prefix = file_key(directory)
                    if settings.get('searchUnsupported'):
                        payload, code = b'', 1
                        channel.send_stderr(b"find: unknown predicate '-printf'\n")
                    else:
                        rows = []
                        for name, content in test_files.items():
                            if prefix is None or (prefix and not name.startswith(prefix.rstrip('/') + '/')): continue
                            if name.split('/')[-1].lower() != 'outcar' and not name.lower().endswith(('.log', '.out')): continue
                            full_path = '/home/tester/project-42/' + name
                            rows.append(f'{output_mtime(name)}.000000\t{len(content)}\t{full_path}\0'.encode())
                        payload = b''.join(rows)
                        if settings.get('searchPartial'):
                            code = 1
                            channel.send_stderr(b'find: permission denied in fixture-only directory\n')
                elif is_command:
                    count('exec_commands')
                    script = shlex.split(command.decode())[2]
                    directory = shlex.split(script.splitlines()[1])[2]
                    (root / 'last-command.json').write_text(json.dumps({'directory': directory, 'script': script}))
                    if 'SLURM_TEST_WAIT' in script: time.sleep(2)
                    if 'sbatch --parsable' in script:
                        count('submissions')
                        payload = b'9001;fixture\n'
                    elif 'SLURM_TEST_ERROR' in script:
                        payload, code = b'partial output\n', 7
                        channel.send_stderr(b'fixture stderr\n')
                    elif 'SLURM_TEST_BIG' in script:
                        payload = b'x' * (2 * 1024 * 1024)
                    else:
                        payload = (directory + '\nfixture command completed\n').encode()
                else:
                    settings = json.loads((root / 'state.json').read_text()) if (root / 'state.json').exists() else {}
                    time.sleep(min(float(settings.get('queueDelay', 0)), 5))
                    include_capacity = b'scontrol show nodes -o' in command
                    if include_capacity:
                        count('capacity_queries')
                    payload = output(include_capacity)
                channel.sendall(payload)
                channel.send_exit_status(code)
                channel.shutdown_write()
                channel.close()
            except Exception:
                pass
        threading.Thread(target=respond, daemon=True).start()
        return True

def serve(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host)
    transport.set_subsystem_handler('sftp', paramiko.SFTPServer, ReadOnlyFiles)
    try:
        interface = Fixture()
        transport.start_server(server=interface)
        channels = []
        while transport.is_active():
            channel = transport.accept(1)
            channels = [active for active in channels if not active.closed]
            if channel is not None:
                channels.append(channel)
    except Exception:
        pass
    finally:
        transport.close()

listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(host.asbytes()).digest()).decode().rstrip("=")
(root / "connection.json").write_text(json.dumps({"port": listener.getsockname()[1], "fingerprint": fingerprint}))
print("Loopback SSH fixture ready", flush=True)
while True:
    client, _ = listener.accept()
    count("connections")
    threading.Thread(target=serve, args=(client,), daemon=True).start()
