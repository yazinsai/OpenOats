import json
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = pathlib.Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with (state / 'requests.jsonl').open('a') as log:
            log.write(json.dumps(body) + '\n')
        if body['model'] == 'slow-test':
            time.sleep(0.5)
        data = [
            {'index': i, 'embedding': [text.lower().count('apple'), text.lower().count('banana'), text.lower().count('papaya'), 0.01]}
            for i, text in enumerate(body['input'])
        ]
        response = json.dumps({'data': data}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(state / 'port').write_text(str(server.server_port))
server.serve_forever()
