import socket, json, time, base64, colorsys
ip='192.168.0.58'
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEPORT,1); s.bind(('',4002))
def xw(b):
    x=0
    for v in b: x^=v
    return bytes(b+[x])
def ble(cmd): return base64.b64encode(xw(cmd+[0]*(19-len(cmd)))).decode()
def pt(op,p): return base64.b64encode(xw([0xBB,(len(p)>>8)&0xff,len(p)&0xff,op]+p)).decode()
def send(m): s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
def pr(*f): send({"cmd":"ptReal","data":{"command":[ble(x) for x in f]}})
send({"cmd":"turn","data":{"value":1}}); time.sleep(0.3)
print("1 fade green"); pr([0x33,0x05,0x0D,0,255,0]); time.sleep(3)
print("2 music red/blue"); pr([0x33,0x05,0x05,0x01]); time.sleep(0.3)
t=time.time()
while time.time()-t<6:
    for rgb in ((255,0,0),(0,0,255)):
        pr([0x33,0x05,0x05,0x00,*rgb]); time.sleep(1/12)
print("3 razer rainbow"); send({"cmd":"razer","data":{"pt":pt(0xB1,[1])}}); time.sleep(0.3)
t=time.time()
while time.time()-t<6:
    r,g,b=[int(c*255) for c in colorsys.hsv_to_rgb(((time.time()-t)/3)%1,1,1)]
    send({"cmd":"razer","data":{"pt":pt(0xB0,[0,1,r,g,b])}}); time.sleep(1/20)
send({"cmd":"razer","data":{"pt":pt(0xB1,[0])}}); time.sleep(0.3)
send({"cmd":"colorwc","data":{"color":{"r":255,"g":220,"b":0},"colorTemInKelvin":0}}); print("4 yellow")
