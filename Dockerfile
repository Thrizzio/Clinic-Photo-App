FROM ghcr.io/cirruslabs/flutter:3.47.4

WORKDIR /workspace
ENV CI=true

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Build-time verification keeps the image useful on a clean Linux machine.
RUN flutter analyze --no-pub
RUN flutter test --no-pub
RUN flutter build apk --debug

ENTRYPOINT ["flutter"]
CMD ["test", "--no-pub"]
