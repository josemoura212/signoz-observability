# Setup do Monitoramento MongoDB

## 1. Criar usuário de monitoramento

```javascript
use admin
db.createUser({
  user: "signoz_monitor",
  pwd: "senha_segura",
  roles: [
    { role: "clusterMonitor", db: "admin" },
    { role: "read", db: "local" }
  ]
})
```

## 2. Habilitar logging estruturado (JSON)

O MongoDB 4.4+ já usa JSON por padrão. Verificar em `mongod.conf`:

```yaml
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
  logRotate: reopen
```

## 3. Configurar .env do agent

Copiar `.env.example` para `.env` e preencher:

```env
SIGNOZ_ENDPOINT=<IP_DO_SERVIDOR_SIGNOZ>
MONGO_ENDPOINT=host.docker.internal:27017
MONGO_MONITOR_USER=signoz_monitor
MONGO_MONITOR_PASSWORD=senha_segura
MONGO_LOG_PATH=/var/log/mongodb
```

## 4. Subir o agent

```bash
docker compose up -d
```
