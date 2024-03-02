FROM ruby
COPY . /app
WORKDIR /app

RUN apt-get update && apt-get install -y mktorrent
RUN bundle
RUN chmod +x /app/redcurry.rb

ENTRYPOINT ["/app/redcurry.rb"]
CMD ["/app/redcurry.rb"]
