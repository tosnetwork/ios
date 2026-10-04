#!/usr/bin/env python3
"""Replay PUBLIC mobile signatures in the actual transaction/action-phase VM.
Requires a pinned local TOS checkout and built emulator. No production node writes.
"""
import argparse,json,os,sys,hashlib
from pathlib import Path
if not __debug__:
 raise SystemExit("PQ tests require enabled Python assertions")
p=argparse.ArgumentParser();p.add_argument('--tos-root',type=Path,required=True);p.add_argument('--emulator',type=Path,required=True);p.add_argument('--wire',type=Path,nargs='+',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
sys.path.insert(0,str(a.tos_root.resolve()/'test/auth-extensions'))
os.environ['EMULATOR_PATH']=str(a.emulator.resolve())
from cells import Cell,from_boc
import native
native.GLOBAL_ID=3
from native import Emulator,active_account,account_data,state_init,internal,outgoing,NOW
sys.path.insert(0,str(a.tos_root.resolve()/'test/falcon-auth'))
from protocol import parse_message,chain

def addr(raw):
 wc,h=raw.split(':');return int(wc),int(h,16)
def uninit(address):
 account=Cell().uint(1,1).addr(address).varuint(0,7).varuint(0,7).uint(0,3).uint(NOW,32).uint(0,1).uint(0,64).coins(0).uint(0,1).uint(0,2)
 return Cell().uint(0,256).uint(0,64).ref(account)
def balance(shard):
 s=shard.refs[0].slice();assert s.uint(1)==1;s.addr();s.varuint(7);s.varuint(7)
 extra=s.uint(3)
 if extra==1:s.uint(256)
 s.uint(32)
 if s.uint(1):s.coins()
 s.uint(64);return s.coins()
def check(result,exit,label):
 assert result['success'],(label,'emulator error',result)
 d=result['details'];assert d['exit']==exit,(label,d,result.get('vm_log','')[-2000:])
 if exit==0:assert not d['aborted'] and (d['action'] is None or d['action']['success']),(label,d)
 return d
records=[]
for path in a.wire:
 x=json.loads(path.read_text());algorithm=x['algorithm'];root=addr(x['module_address']);wallet=addr(x['wallet_address'])
 def boc(k):return from_boc(x[k])
 mc,md,wc,wd=boc('module_code'),boc('module_data'),boc('wallet_code'),boc('wallet_data')
 assert state_init(mc,md).hash==root[1].to_bytes(32,'big')
 assert state_init(wc,wd).hash==wallet[1].to_bytes(32,'big')
 ms,ws=active_account(root,mc,md),active_account(wallet,wc,wd)
 body=boc('submission');request=boc('request')
 assert body.refs[0].refs[0].hash==request.hash
 e=Emulator(16);events=[]
 try:
  mr=e.send(ms,internal((0,17),root,body,10_000_000_000));check(mr,0,'module')
  messages=outgoing(from_boc(mr['transaction']));assert len(messages)==1
  relay=parse_message(messages[0]);assert relay['sender']==root and relay['destination']==wallet
  assert relay['body'].hash==body.refs[0].hash and relay['bounce']==1
  assert account_data(from_boc(mr['shard_account']))[0].hash==md.hash
  e.lt=max(e.lt,relay['created_lt']);wr=e.send(ws,messages[0]);check(wr,0,'wallet')
  next_ws=from_boc(wr['shard_account']);data=account_data(next_ws)[0].slice()
  data.uint(321);assert data.maybe() is None;auth=data.ref().slice()
  assert (auth.uint(2),auth.uint(64),auth.uint(64),auth.uint(256))==(2,0,1,root[1])
  outs=outgoing(from_boc(wr['transaction']));assert len(outs)==1
  payment=parse_message(outs[0]);destination=(0,int('22'*32,16))
  assert payment['sender']==wallet and payment['destination']==destination and payment['value']==10_000_000
  assert payment['body'].slice().uint(32)==0
  b=payment['body'].bits[32:];raw=bytes(int(b[j:j+8],2) for j in range(0,len(b),8));assert raw.decode()=='PQ TOS 测试 🌌'
  e.lt=max(e.lt,payment['created_lt']);rr=e.send(uninit(destination),outs[0]);assert rr['success']
  assert rr['details'].get('skipped') is True, rr['details']
  rt=from_boc(rr['transaction']);ri=rt.refs[0].slice().maybe()
  assert ri is not None and ri.hash==outs[0].hash and not outgoing(rt)
  credit=balance(from_boc(rr['shard_account']))
  ts=rt.slice();assert ts.uint(4)==7;assert ts.uint(256)==destination[1]
  ts.uint(64);ts.uint(256);ts.uint(64);ts.uint(32);assert ts.uint(15)==0
  ts.uint(2);ts.uint(2);ts.ref();fees=ts.coins();assert ts.maybe() is None
  assert credit==10_000_000-fees and credit>0
  # Same exact mobile submission forwarded again must not spend twice.
  replay=e.send(from_boc(mr['shard_account']),internal((0,17),root,body,10_000_000_000));check(replay,0,'replay module')
  rm=outgoing(from_boc(replay['transaction']));assert len(rm)==1
  e.lt=max(e.lt,parse_message(rm[0])['created_lt']);rejected=e.send(next_ws,rm[0]);check(rejected,1804,'replay account')
  assert account_data(from_boc(rejected['shard_account']))[0].hash==account_data(next_ws)[0].hash
  assert not [m for m in outgoing(from_boc(rejected['transaction'])) if not parse_message(m)['bounced']]
  sig=bytearray();c=body.refs[1]
  while True:
   assert len(c.bits)%8==0
   sig.extend(int(c.bits[j:j+8],2) for j in range(0,len(c.bits),8))
   if not c.refs:break
   c=c.refs[0]
  sig[10]^=1
  malformed=Cell().uint(0x4d4c4434 if algorithm==1 else 0x46414c31,32).uint(0,64).ref(body.refs[0]).ref(chain(bytes(sig)))
  bad=e.send(ms,internal((0,17),root,malformed,10_000_000_000));check(bad,1808,'signature tamper')
  assert not outgoing(from_boc(bad['transaction']))
  old=Emulator(15)
  try:
   before=old.send(ms,internal((0,17),root,body,10_000_000_000))
   assert before['success'] and before['details']['exit']!=0 and not outgoing(from_boc(before['transaction']))
  finally:old.close()
  records.append(dict(platform=x['platform'],algorithm=algorithm,passed=True,recipient_credit=credit,recipient_fees=fees,recipient_compute='skipped-no-state; exact inbound credit minus transaction fees, no outgoing',
   request_hash=request.hash.hex(),module_transaction=mr['transaction'],wallet_transaction=wr['transaction'],recipient_transaction=rr['transaction'],
   controls=['actual-module-forwarding','actual-wallet-action','actual-recipient-credit','account-nonce-advanced-once','replay-rejected-exit1804','tamper-rejected-exit1808','pre-activation-rejected'],
   wire_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
 finally:e.close()
a.out.write_text(json.dumps(dict(passed=True,scope='Local transaction emulator, public mobile signatures, unchanged fixture gas limits/prices. Not full-node deployment or production activation.',emulator_sha256=hashlib.sha256(a.emulator.read_bytes()).hexdigest(),records=records),indent=2)+'\n')
print(json.dumps(dict(passed=True,executions=len(records),platform_profiles=[(x['platform'],x['algorithm']) for x in records])))
