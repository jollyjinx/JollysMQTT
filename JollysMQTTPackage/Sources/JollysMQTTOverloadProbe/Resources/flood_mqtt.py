#!/usr/bin/env python3

import socket
import struct
import sys


def variable_length(value):
    encoded = bytearray()
    while True:
        byte = value % 128
        value //= 128
        if value:
            byte |= 0x80
        encoded.append(byte)
        if not value:
            return bytes(encoded)


def mqtt_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("!H", len(encoded)) + encoded


host = sys.argv[1]
port = int(sys.argv[2])
topic = sys.argv[3]
message_count = int(sys.argv[4])
payload_bytes = int(sys.argv[5])

client_id = mqtt_string("jolly-ticket3-flood")
variable_header = b"\x00\x04MQTT\x04\x02\x00\x3c"
connect_body = variable_header + client_id
connect_packet = b"\x10" + variable_length(len(connect_body)) + connect_body

payload = b"A" * payload_bytes
publish_body = mqtt_string(topic) + payload
publish_packet = b"\x30" + variable_length(len(publish_body)) + publish_body

sent = 0
with socket.create_connection((host, port), timeout=5) as connection:
    connection.sendall(connect_packet)
    response = connection.recv(4)
    if response != b"\x20\x02\x00\x00":
        raise RuntimeError("Broker rejected benchmark publisher")
    try:
        for _ in range(message_count):
            connection.sendall(publish_packet)
            sent += 1
    except (BrokenPipeError, ConnectionResetError):
        pass

print(sent)
