"""
Amigo Secreto - servidor em Python (Flask).

Como rodar no VS Code:
    pip install -r requirements.txt
    python app.py
Depois abra http://localhost:5000 no navegador.

O banco de dados continua no Supabase (projeto amigo-secreto) e o Pix
continua no Mercado Pago. Este arquivo serve a página e repassa os
pedidos da página para o Supabase.
"""
import os

import requests
from flask import Flask, Response, jsonify, request, send_from_directory

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://sdjeaddpdoldbnlsctuj.supabase.co")
SUPABASE_KEY = os.environ.get(
    "SUPABASE_KEY",
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNkamVhZGRwZG9sZGJubHNjdHVqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ3ODExODIsImV4cCI6MjExMDM1NzE4Mn0.WZMLed5H-gvttN_97ks4Tv4TuZNm5aIGVuF4jQrDsD0",
)

# Funções do banco que a página pode chamar
FUNCOES = {
    "criar_grupo", "ver_grupo", "adicionar_participante", "remover_participante",
    "sortear", "desfazer_sorteio", "ver_participante", "salvar_desejos",
    "adicionar_restricao", "remover_restricao", "salvar_desejos_admin",
    "salvar_foto", "salvar_foto_admin",
}

PASTA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")
app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 1024 * 1024  # fotos já chegam reduzidas


def cabecalhos():
    return {
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type": "application/json",
    }


def repassar(resp: requests.Response) -> Response:
    return Response(resp.content, status=resp.status_code,
                    content_type=resp.headers.get("Content-Type", "application/json"))


@app.get("/")
def pagina():
    return send_from_directory(PASTA, "index.html")


@app.post("/api/rpc/<nome>")
def rpc(nome):
    if nome not in FUNCOES:
        return jsonify(message="Função desconhecida"), 404
    try:
        r = requests.post(f"{SUPABASE_URL}/rest/v1/rpc/{nome}",
                          json=request.get_json(silent=True) or {},
                          headers=cabecalhos(), timeout=20)
    except requests.RequestException:
        return jsonify(message="Sem conexão com o banco. Tente de novo."), 502
    return repassar(r)


@app.post("/api/pix")
def pix():
    try:
        r = requests.post(f"{SUPABASE_URL}/functions/v1/pix-criar",
                          json=request.get_json(silent=True) or {},
                          headers=cabecalhos(), timeout=30)
    except requests.RequestException:
        return jsonify(message="Não foi possível gerar o Pix agora."), 502
    return repassar(r)


if __name__ == "__main__":
    porta = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=porta, debug=os.environ.get("DEBUG") == "1")
