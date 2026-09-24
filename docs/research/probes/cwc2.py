import socket, json, time, colorsys
ip='192.168.0.58'
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
def send(m): s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
def col(r,g,b): send({"cmd":"colorwc","data":{"color":{"r":r,"g":g,"b":b},"colorTemInKelvin":0}})
send({"cmd":"turn","data":{"value":1}})
t=time.time()
while time.time()-t<10:
    col(*[int(c*255) for c in colorsys.hsv_to_rgb(((time.time()-t)/4)%1,1,1)]); time.sleep(1/8)
t=time.time()
while time.time()-t<8:
    col(255,0,0); time.sleep(0.25); col(0,0,255); time.sleep(0.25)
col(255,220,0)
