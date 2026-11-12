# syntax=docker/dockerfile:1
FROM node:24-alpine
WORKDIR /app
COPY --chown=node:node server.js ./
RUN mkdir -p /app/data && chown node:node /app/data
ENV NODE_ENV=production PORT=8080 HOST=0.0.0.0 DATA_FILE=/app/data/reports.json
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["node", "-e", "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["node", "server.js"]
