FROM ruby
COPY . /app
WORKDIR /app

RUN bundle
RUN chmod +x /app/redcurry.rb

VOLUME ["/app/curry.yaml"]
ENTRYPOINT ["/app/redcurry.rb"]
CMD ["/app/redcurry.rb", "LINK", "SRC", "DES"]
