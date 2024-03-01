FROM ruby
COPY . /app
WORKDIR /app

RUN bundle
RUN chmod +x /app/redcurry.rb

VOLUME ["/app/curry.yml"]
ENTRYPOINT ["/app/redcurry.rb"]
CMD ["/app/redcurry.rb", "LINK", "SRC", "DES"]
