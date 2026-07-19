FROM dart:stable AS build
WORKDIR /app
COPY . .
RUN echo "sample dockerfile"
FROM alpine:3.21
CMD ["echo", "sample"]
