# syntax=docker/dockerfile:1
FROM node:20-alpine
WORKDIR /app
COPY server.js ./
# sightings live here — mount a volume at /app/data if you want them to survive restarts
RUN mkdir -p /app/data
ENV PORT=8080 HOST=0.0.0.0 DATA_FILE=/app/data/sightings.json
EXPOSE 8080
CMD ["node", "server.js"]
