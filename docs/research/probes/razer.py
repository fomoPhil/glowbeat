import socket, json, time, sys, base64, colorsys
ip=sys.argv[1]; hz=float(sys.argv[2]); secs=float(sys.argv[3]); segs=int(sys.argv[4]) if len(sys.argv)>4 else 1
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('',4002)); s.settimeout(1.0)
def pt(op,payload):
    b=[0xBB,(len(payload)>>8)&0xff,len(payload)&0xff,op]+payload
    x=0
    for v in b: x^=v
    b.append(x); return base64.b64encode(bytes(b)).decode()
def send(m): s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
def status():
    send({"cmd":"devStatus","data":{}})
    try: return json.loads(s.recv(4096))
    except socket.timeout: return "no reply"
send({"cmd":"turn","data":{"value":1}}); time.sleep(0.2)
on=pt(0xB1,[1]); print("rz on pt:",on); send({"cmd":"razer","data":{"pt":on}}); time.sleep(0.3)
n=0; t0=time.time()
while time.time()-t0<secs:
    h=((time.time()-t0)*0.5)%1.0
    r,g,b=[int(c*255) for c in colorsys.hsv_to_rgb(h,1,1)]
    payload=[0,segs]+[r,g,b]*segs
    send({"cmd":"razer","data":{"pt":pt(0xB0,payload)}}); n+=1
    time.sleep(1/hz)
print("frames sent:",n,"in",round(time.time()-t0,2),"s")
print("status during rz:",status())
send({"cmd":"razer","data":{"pt":pt(0xB1,[0])}}); time.sleep(0.3)
print("status after rz off:",status())
