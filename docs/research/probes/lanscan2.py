import socket, json, time, struct
MCAST='239.255.255.250'
IPS=['192.168.0.58','192.168.0.102','192.168.0.107','192.168.0.158','192.168.0.162','192.168.0.191']
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEPORT,1)
s.bind(('',4002))
mreq=struct.pack('4s4s',socket.inet_aton(MCAST),socket.inet_aton('192.168.0.23'))
s.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,mreq)
s.settimeout(0.5)
msg=json.dumps({"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}).encode()
tx=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
tx.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_IF,socket.inet_aton('192.168.0.23'))
tx.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_TTL,2)
found={}
for i in range(3):
    tx.sendto(msg,(MCAST,4001))
    for ip in IPS:
        tx.sendto(msg,(ip,4001))
        tx.sendto(json.dumps({"msg":{"cmd":"devStatus","data":{}}}).encode(),(ip,4003))
    end=time.time()+2
    while time.time()<end:
        try:
            d,a=s.recvfrom(4096); found[a[0]]=json.loads(d)
        except socket.timeout: pass
        except Exception as e: print("err",e)
print(json.dumps(found,indent=1)); print("devices:",len(found))
