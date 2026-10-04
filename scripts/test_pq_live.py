#!/usr/bin/env python3
"""Disposable loopback chain; actual mobile PUBLIC test signatures, fee-paid delivery."""
import argparse, asyncio, base64, json, re, sys, time, urllib.request
from pathlib import Path
if not __debug__:
 raise SystemExit("PQ tests require enabled Python assertions")
p=argparse.ArgumentParser();p.add_argument('--tos-root',type=Path,required=True);p.add_argument('--build',type=Path,required=True);p.add_argument('--workdir',type=Path,required=True);p.add_argument('--records',type=Path,required=True);p.add_argument('--rpc',default='http://127.0.0.1:28545/jsonRPC');p.add_argument('--control',default='127.0.0.1:28745');a=p.parse_args()
if not a.rpc.startswith('http://127.0.0.1:') or not a.control.startswith('127.0.0.1:'):raise ValueError('disposable loopback chain required')
sys.path[:0]=[str(a.tos_root/'test/tostester/src'),str(a.tos_root/'test/pq-readiness'),str(a.tos_root/'test/auth-extensions')]
from pytosiq_core import Address,Cell,StateInit
from pytosiq_core.tlb.transaction import Transaction
from contract.pq_lite_transport import LiteClientTransport
from live_chain import funded_payer,wait_for
T=LiteClientTransport(a.build/'lite-client/lite-client',a.workdir/'lite-client.json',attempts=60)
def rpc(method,**params):
 req=urllib.request.Request(a.rpc,json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode(),{'content-type':'application/json'})
 with urllib.request.urlopen(req,timeout=60) as f:obj=json.load(f)
 if 'error' in obj:raise RuntimeError(obj['error'])
 return obj['result']
def transactions(addr):
 result=rpc('getTransactions',address=addr.to_str(False),limit=12)
 if isinstance(result,dict):result=result.get('transactions',[])
 return [(Cell.one_from_boc(base64.b64decode(x['data'])),x) for x in result if x.get('data')]
def tx_for(addr,bodyhash):
 for cell,raw in transactions(addr):
  tx=Transaction.deserialize(cell.begin_parse())
  if tx.in_msg and tx.in_msg.body.hash==bodyhash:return cell,tx,raw
 return None
def checked_phase(tx):
 d=tx.description
 assert not d.aborted and getattr(d.compute_ph,'success',False) and (d.action is None or d.action.success)
def mark_for(addr,messagehash):
 for cell,raw in transactions(addr):
  tx=Transaction.deserialize(cell.begin_parse())
  if tx.in_msg and tx.in_msg.cell.hash==messagehash:return cell,tx,raw
 return None
a.records.mkdir(parents=True,exist_ok=True)
initial=[json.loads(x.read_text()) for x in sorted((a.records/'initial').glob('*.json'))]
assert len(initial)==2 and T.global_id()==3 and T.global_version()>=19
code=Cell.one_from_boc(base64.b64decode(initial[0]['wallet_code']))
payer,key=funded_payer(T,a.control,code,3,tos=180)
class Blueprint:
 def __init__(self,record,prefix):
  self.address=Address(record[prefix+'_address']);self.state_init=StateInit(code=Cell.one_from_boc(base64.b64decode(record[prefix+'_code'])),data=Cell.one_from_boc(base64.b64decode(record[prefix+'_data'])))
  assert self.state_init.serialize().hash==self.address.hash_part
for record in initial:
 for prefix,value in [('module',5_000_000_000),('wallet',20_000_000_000)]:
  blueprint=Blueprint(record,prefix)
  try:
   data=T.account_data(blueprint.address)
  except Exception:
   data=None
  if data is None: asyncio.run(T.deploy(blueprint,value))
  elif prefix=='module': assert data.hash==blueprint.state_init.data.hash
  else:
   auth=T.read_auth(blueprint.address)
   assert auth.mode==2 and auth.epoch==0 and auth.module_hash==Address(record['module_address']).hash_part
_,now=T.head()
(a.records/'ready.json').write_text(json.dumps(dict(chain_time=now,nonces=','.join(str(T.read_auth(Address(r['wallet_address'])).nonce) for r in initial),network=3,vm=T.global_version(),payer=payer.address.to_str(False))))
print('DEPLOYED_PUBLIC_MOBILE_ACCOUNTS',now,flush=True)
events=[]
for platform,nonce in [('ios',0),('android',1)]:
 for alg in (1,2):
  path=a.records/f'{platform}-live-{alg}.json'
  deadline=time.monotonic()+1800
  while not path.exists():
   if time.monotonic()>deadline:raise TimeoutError(f'waiting for actual mobile signature {path.name}')
   time.sleep(1)
  record=json.loads(path.read_text());assert record['platform']==platform and int(record['algorithm'])==alg;nonce=int(record['nonce'])
  root=Address(record['module_address']);wallet=Address(record['wallet_address']);target=Address('0:'+'22'*32)
  assert T.read_auth(wallet).nonce==nonce
  body=Cell.one_from_boc(base64.b64decode(record['submission']));request=Cell.one_from_boc(base64.b64decode(record['request']))
  # Reject a changed signature through the actual verifier. Signature is second ref.
  changed=bytearray(body.refs[1].begin_parse().load_bytes(127));changed[10]^=1
  from pytosiq_core import Builder
  badsig=Builder().store_bytes(bytes(changed))
  for ref in body.refs[1].refs:badsig.store_ref(ref)
  broken=Cell(body.bits,[body.refs[0],badsig.end_cell()])
  before=T.balance(target)
  asyncio.run(T.submit_internal(root,broken,2_000_000_000))
  rejected=wait_for(lambda:tx_for(root,broken.hash),'modified mobile signature transaction')
  assert rejected[1].description.compute_ph.exit_code==1808 and not rejected[1].out_msgs
  assert T.read_auth(wallet).nonce==nonce and T.balance(target)==before
  broadcast=asyncio.run(T.submit_internal(root,body,2_000_000_000))
  module=wait_for(lambda:tx_for(root,body.hash),'actual mobile submission module transaction')
  checked_phase(module[1]);assert len(module[1].out_msgs)==1
  forwarded=module[1].out_msgs[0]
  account=wait_for(lambda:mark_for(wallet,forwarded.cell.hash),'exact forwarded AUTH wallet transaction')
  checked_phase(account[1]);assert len(account[1].out_msgs)==1
  emitted=account[1].out_msgs[0];assert emitted.info.dest==target and emitted.info.value.tomis==10_000_000
  receipt=wait_for(lambda:mark_for(target,emitted.cell.hash),'exact wallet outgoing message delivery')
  r=receipt[1];assert not r.out_msgs and r.description.credit_ph.credit.tomis==10_000_000
  # An uninitialized passive recipient credits funds despite compute(no_state)
  # and aborted=true. Accept only this precise passive case; contract execution
  # still requires successful compute/action and aborted=false.
  if r.description.compute_ph.type_=='skipped':
   assert r.description.compute_ph.reason.type_=='no_state' and r.description.action is None and r.description.bounce is None
   recipient_kind='passive-no-state-credit'
  else: checked_phase(r);recipient_kind='successful-contract-credit'
  assert r.in_msg.cell.hash==emitted.cell.hash
  expected_comment=bytes(4)+'PQ TOS 测试 🌌'.encode();assert emitted.body.begin_parse().load_bytes(len(expected_comment))==expected_comment
  assert T.read_auth(wallet).nonce==nonce+1
  after=T.balance(target);assert after-before==10_000_000-r.total_fees.tomis
  # Re-deliver the same authenticated envelope: root can forward; wallet rejects replay.
  prior=account[0].hash
  asyncio.run(T.submit_internal(root,body,2_000_000_000))
  def replay():
   for cell,raw in transactions(wallet):
    tx=Transaction.deserialize(cell.begin_parse())
    if cell.hash!=prior and tx.in_msg and tx.in_msg.body.hash==forwarded.body.hash and tx.description.compute_ph.type_=='vm' and tx.description.compute_ph.exit_code==1804:return cell,tx,raw
  replayed=wait_for(replay,'replay wallet rejection')
  for returned in replayed[1].out_msgs:
   assert returned.info.bounced and returned.info.dest==root
   assert 0<=returned.info.value.tomis<=replayed[1].in_msg.info.value.tomis
  assert T.read_auth(wallet).nonce==nonce+1 and T.balance(target)==after
  def evidence(item):return dict(hash=item[0].hash.hex(),boc=base64.b64encode(item[0].to_boc()).decode(),rpc=item[2])
  events.append(dict(platform=platform,algorithm=alg,recipient_kind=recipient_kind,nonce_before=nonce,nonce_after=nonce+1,broadcast=broadcast,recipient_delta=after-before,module=evidence(module),wallet=evidence(account),receipt=evidence(receipt),tampered=evidence(rejected),replay=evidence(replayed)))
  (a.records/f'{platform}-live-{alg}.result.json').write_text(json.dumps(events[-1],indent=2))
  print('LIVE_MOBILE_PASS',platform,alg,flush=True)
 if platform=='ios':
  _,now=T.head();(a.records/'android-ready.json').write_text(json.dumps(dict(chain_time=now,nonces=','.join(str(T.read_auth(Address(r['wallet_address'])).nonce) for r in initial))))
(a.records/'live-result.json').write_text(json.dumps(dict(passed=True,scope='disposable-localnet VM19; actual mobile public signatures; selected owned node trust anchor',events=events),indent=2))
print('ALL_FOUR_LIVE_MOBILE_CASES_PASSED',flush=True)
