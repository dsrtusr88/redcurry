FROM ruby
COPY . /app
WORKDIR /app

RUN bundle
RUN chmod +x /app/redcurry.rb

ENTRYPOINT ["/app/redcurry.rb"]
CMD ["/app/redcurry.rb"]
