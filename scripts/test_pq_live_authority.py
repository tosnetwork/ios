import argparse,json,sys,asyncio,base64,urllib.request,time
from pathlib import Path
if not __debug__:
 raise SystemExit("PQ tests require enabled Python assertions")
p=argparse.ArgumentParser();p.add_argument('--tos-root',type=Path,required=True);p.add_argument('--build',type=Path,required=True);p.add_argument('--records',type=Path,required=True);p.add_argument('--workdir',type=Path,required=True);p.add_argument('--rpc',default='http://127.0.0.1:28545/jsonRPC');p.add_argument('--control',default='127.0.0.1:28745');a=p.parse_args()
if not a.rpc.startswith('http://127.0.0.1:') or not a.control.startswith('127.0.0.1:'):raise ValueError('disposable loopback chain required')
sys.path[:0]=[str(a.tos_root/'test/tostester/src'),str(a.tos_root/'test/pq-readiness'),str(a.tos_root/'test/auth-extensions')]
from pytosiq_core import Address,Cell,Builder
from contract import WalletV5
from contract.pq_lite_transport import LiteClientTransport
from live_chain import funded_payer,wait_for
T=LiteClientTransport(a.build/'lite-client/lite-client',a.workdir/'lite-client.json',attempts=60)
records=[json.loads((a.records/f'android-live-{alg}.json').read_text()) for alg in (1,2)]
payer,key=funded_payer(T,a.control,Cell.one_from_boc(base64.b64decode(records[0]['wallet_code'])),3,tos=60)
def txs(addr):
 req=urllib.request.Request(a.rpc,json.dumps(dict(jsonrpc='2.0',id=1,method='getTransactions',params=dict(address=addr.to_str(False),limit=12))).encode(),{'content-type':'application/json'})
 with urllib.request.urlopen(req,timeout=60) as f:rows=json.load(f)['result']
 from pytosiq_core.tlb.transaction import Transaction
 return [(row,Transaction.deserialize(Cell.one_from_boc(base64.b64decode(row['data'])).begin_parse())) for row in rows]
results=[]
for record in records:
 wallet=Address(record['wallet_address']);root=Address(record['module_address']);target=Address('0:'+'33'*32)
 state=T.read_auth(wallet);old=T.account_data(wallet).hash;balance=T.balance(target)
 _,now=T.head()
 payload=WalletV5(None,wallet,3).transfer_payload(target,10_000_000)
 request=Builder().store_int(3,32).store_address(wallet).store_uint(state.epoch,64).store_uint(state.nonce,64).store_uint(now+600,32).store_uint(0,8).store_ref(payload).end_cell()
 envelope=Builder().store_uint(0x41555448,32).store_ref(request).store_uint(0,1).end_cell()
 asyncio.run(T.submit_internal(wallet,envelope,1_000_000_000))
 def forged():
  for row,tx in txs(wallet):
   if tx.in_msg and tx.in_msg.body.hash==envelope.hash:return row,tx
 row,tx=wait_for(forged,'fresh-counter direct AUTH fails wrong-root provenance')
 assert tx.description.compute_ph.exit_code==1800
 assert T.account_data(wallet).hash==old and T.read_auth(wallet).nonce==state.nonce and T.balance(target)==balance
 for msg in tx.out_msgs:assert msg.info.bounced and msg.info.dest==payer.address
 results.append(dict(algorithm=record['algorithm'],fresh_nonce=state.nonce,forged_sender=payer.address.to_str(False),exit_code=1800,transaction=row,unchanged_auth_data=True,no_destination_credit=True))
(a.records/'live-authority-controls.json').write_text(json.dumps(dict(passed=True,controls=results),indent=2));print('LIVE_WRONG_ROOT_AUTHORITY_CONTROLS_PASS',flush=True)
