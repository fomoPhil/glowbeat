import socket, json, time, base64, colorsys
ip='192.168.0.58'
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
def ble(cmd):
    b=cmd+[0]*(19-len(cmd)); x=0
    for v in b: x^=v
    return base64.b64encode(bytes(b+[x])).decode()
def send(m): s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
def pr(*frames): send({"cmd":"ptReal","data":{"command":[ble(f) for f in frames]}})
send({"cmd":"turn","data":{"value":1}}); time.sleep(0.3)
print("A fade red"); pr([0x33,0x05,0x0D,255,0,0]); time.sleep(3)
print("B enter music once"); pr([0x33,0x05,0x05,0x01]); time.sleep(0.3)
t=time.time()
while time.time()-t<6:
    for rgb in ((255,0,0),(0,255,0)):
        pr([0x33,0x05,0x05,0x00,*rgb]); time.sleep(1/12)
print("C 20Hz sweep"); t=time.time()
while time.time()-t<6:
    r,g,b=[int(c*255) for c in colorsys.hsv_to_rgb(((time.time()-t)/3)%1,1,1)]
    pr([0x33,0x05,0x05,0x00,r,g,b]); time.sleep(1/20)
send({"cmd":"colorwc","data":{"color":{"r":255,"g":255,"b":255},"colorTemInKelvin":0}})
print("done, white")
