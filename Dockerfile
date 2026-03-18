FROM perl:5.40-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cpanminus \
      build-essential \
      ca-certificates \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && cpanm --notest Plack Starman LWP::UserAgent LWP::Protocol::https URI URI::Escape

WORKDIR /app
COPY app.psgi .

EXPOSE 8081
CMD ["plackup", "-s", "Starman", "-p", "8081", "app.psgi"]
