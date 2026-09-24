import socket, json, time, sys
ip=sys.argv[1]
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('',4002)); s.settimeout(1.5)
def send(m): s.sendto(json.dumps({"msg":m}).encode(),(ip,4003))
def status():
    send({"cmd":"devStatus","data":{}})
    try: return json.loads(s.recv(4096))
    except socket.timeout: return "no reply"
print("before:",status())
send({"cmd":"turn","data":{"value":1}}); time.sleep(0.3)
for rgb in [(255,0,0),(0,255,0),(0,0,255)]:
    send({"cmd":"colorwc","data":{"color":{"r":rgb[0],"g":rgb[1],"b":rgb[2]},"colorTemInKelvin":0}}); time.sleep(0.7)
send({"cmd":"brightness","data":{"value":60}}); time.sleep(0.3)
print("after:",status())
