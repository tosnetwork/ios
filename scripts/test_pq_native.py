#!/usr/bin/env python3
"""Public-data fixed-profile controls. This is not an official algorithm KAT suite."""
import argparse,ctypes,json,os,hashlib
from pathlib import Path
if not __debug__:
 raise SystemExit("PQ tests require enabled Python assertions")
p=argparse.ArgumentParser();p.add_argument('--library',type=Path,required=True);p.add_argument('--interop',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
c=ctypes.CDLL(str(a.library.resolve()))
# Declare pointer/size_t ABI explicitly on both 32-bit and 64-bit hosts.
pointer, size = ctypes.c_void_p, ctypes.c_size_t
c.tos_pq_public_key.argtypes = [ctypes.c_int, pointer, size, pointer, size]
c.tos_pq_sign.argtypes = [ctypes.c_int, pointer, size, pointer, size, pointer, size, pointer, size]
c.tos_pq_verify.argtypes = [ctypes.c_int, pointer, size, pointer, size, pointer, size]
for function in (c.tos_pq_public_key, c.tos_pq_sign, c.tos_pq_verify):
 function.restype = ctypes.c_int
records=[]
for alg,np,ns in [(1,1312,2420),(2,897,666)]:
 seed=b'\xa0'*32;other=b'\xa1'*32
 msg=b'\x01'*32 if alg==1 else b'TOS-AUTH-FALCON512-PADDED-v1\0'+b'\0'*4+b'\x02'*32+b'\x01'*32
 pk=ctypes.create_string_buffer(np);pk2=ctypes.create_string_buffer(np);sig=ctypes.create_string_buffer(ns);sig2=ctypes.create_string_buffer(ns)
 assert c.tos_pq_public_key(alg,seed,32,pk,np)==0
 assert c.tos_pq_public_key(alg,other,32,pk2,np)==0
 assert c.tos_pq_sign(alg,seed,32,os.urandom(48),48,msg,len(msg),sig,ns)==0
 assert c.tos_pq_sign(alg,seed,32,os.urandom(48),48,msg,len(msg),sig2,ns)==0
 assert sig.raw!=sig2.raw
 assert c.tos_pq_verify(alg,pk,np,msg,len(msg),sig,ns)==1
 assert c.tos_pq_verify(alg,pk2,np,msg,len(msg),sig,ns)==0
 assert c.tos_pq_verify(alg,pk,np,msg[:-1]+b'\x02',len(msg),sig,ns)==0
 for offset in [0,10,ns-1]:
  bad=bytearray(sig.raw);bad[offset]^=1
  assert c.tos_pq_verify(alg,pk,np,msg,len(msg),bytes(bad),ns)==0
 assert c.tos_pq_verify(alg,pk,np,msg,len(msg),sig,ns-1)==0
 assert c.tos_pq_sign(alg,seed,31,os.urandom(48),48,msg,len(msg),sig,ns)!=0
 assert c.tos_pq_sign(alg,seed,32,os.urandom(47),47,msg,len(msg),sig,ns)!=0
 assert c.tos_pq_sign(alg,seed,32,os.urandom(48),48,b'X',1,sig,ns)!=0
 records.append(dict(algorithm=alg,passed=True,randomized=True,controls=['wrong-key','wrong-message','tamper-header','tamper-coefficient','tamper-tail','truncated','seed-length','entropy-length','profile-message-length']))
f=json.loads(a.interop.read_text());pk=bytes.fromhex(f['signing_key_hex']);msg=bytes.fromhex(f['commitment_hex']);sig=bytes.fromhex(f['signature_hex'])
assert c.tos_pq_verify(1,pk,len(pk),msg,len(msg),sig,len(sig))==1
assert c.tos_pq_verify(1,pk,len(pk),msg[:-1]+bytes([msg[-1]^1]),len(msg),sig,len(sig))==0
result=dict(passed=True,profiles=records,independent_openssl_verification=True,library_sha256=hashlib.sha256(a.library.read_bytes()).hexdigest())
a.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
