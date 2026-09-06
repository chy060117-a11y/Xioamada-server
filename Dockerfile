FROM dart:stable
WORKDIR /app
COPY bin/ bin/
EXPOSE 8080
CMD ["dart", "run", "bin/server.dart", "8080"]
