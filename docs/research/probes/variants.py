import socket, json, time, base64
ip='192.168.0.58'
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('',4002)); s.settimeout(0.5)
def xorwrap(b):
    x=0
    for v in b: x^=v
    return b+[x]
def pt(op,payload): return base64.b64encode(bytes(xorwrap([0xBB,(len(payload)>>8)&0xff,len(payload)&0xff,op]+payload))).decode()
def send(m):
    s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
    try: return s.recv(4096)
    except socket.timeout: return None
def ble(cmd):
    b=cmd+[0]*(19-len(cmd)); return base64.b64encode(bytes(xorwrap(b))).decode()
def stream(name,frame_fn,secs=4):
    print(name); t=time.time()
    while time.time()-t<secs:
        frame_fn(); time.sleep(1/20)
send({"cmd":"turn","data":{"value":1}})
print("rz on reply:",send({"cmd":"razer","data":{"pt":pt(0xB1,[1])}}))
stream("A red  razer g0 segs1", lambda: send({"cmd":"razer","data":{"pt":pt(0xB0,[0,1,255,0,0])}}))
stream("B green razer g1 segs1", lambda: send({"cmd":"razer","data":{"pt":pt(0xB0,[1,1,0,255,0])}}))
stream("C yellow razer g0 segs15", lambda: send({"cmd":"razer","data":{"pt":pt(0xB0,[0,15]+[255,255,0]*15)}}))
stream("D magenta razer g0 segs20", lambda: send({"cmd":"razer","data":{"pt":pt(0xB0,[0,20]+[255,0,255]*20)}}))
send({"cmd":"razer","data":{"pt":pt(0xB1,[0])}})
print("ptReal reply:",send({"cmd":"ptReal","data":{"command":[ble([0x33,0x05,0x02,0,255,255])]}}))
stream("E cyan ptReal 33 05 02", lambda: send({"cmd":"ptReal","data":{"command":[ble([0x33,0x05,0x02,0,255,255])]}}))
stream("F white ptReal 33 05 0d 01", lambda: send({"cmd":"ptReal","data":{"command":[ble([0x33,0x05,0x0d,0x01,255,255,255])]}}))
stream("G orange ptReal 33 05 15 01", lambda: send({"cmd":"ptReal","data":{"command":[ble([0x33,0x05,0x15,0x01,255,120,0])]}}))
send({"cmd":"colorwc","data":{"color":{"r":0,"g":0,"b":255},"colorTemInKelvin":0}})
print("back to blue")
