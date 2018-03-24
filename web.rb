#!/usr/bin/env ruby
require 'sinatra'
require 'sass'
require 'uea-stemmer'
require 'stopwords'

require 'newrelic_rpm'

require './models'

MIN_WORD_CLOUD_COUNT = 3
PAGE_HEADER_HEIGHT = 44 # TODO pass this in to sass somehow

RESOURCE_VIEWS = {
  authors:         :list,
  books:           :books,
  saved:           :books,
  borrows:         :cal_heatmap,
  prc_year_levels: :word_cloud,
  returns:         :cal_heatmap,
  subjects:        :word_cloud,
  words:           :word_cloud
}.freeze

DATE_RESOURCES = %i(
  borrows
  returns
)


def git_sha
  ENV['HEROKU_SLUG_COMMIT'] && ENV['HEROKU_SLUG_COMMIT'][0..6]
end

def books(opts = {})
  if opts.empty?
    my_books.all(:isbn.not => nil, :order => :main_title)
  else
    resource, value = *opts.flatten
    case resource
    when :words
      current_books_by_word(value)
    when :borrows
      current_books_by_loan(issued: value)
    when :returns
      current_books_by_loan(returned: value)
    else
      if (parent = my_books.send(resource).first(value: value))
        parent.books(order: :main_title)
      else
        []
      end
    end
  end
end

def current_books_by_word(value)
  ['%% %s', '%s %%', "%%%s'%%", "%% %s'%%", "%s, %%", "%% %s,%%", "%% %s!%%"]
    .inject(my_books.all(:main_title.like => '%% %s %%' % value, order: :main_title)) { |collection, pat|
      collection | my_books.all(:main_title.like => pat % value, order: :main_title)
    }
end

def current_books_by_loan(opts = {})
  my_books.loans(opts).map(&:book).sort_by(&:main_title)
end

def get_isbn(book)
  (book.img_url || '')[/isbn=([^\/]+)/, 1]
end

def books_path(value=nil)
  "/books/#{value if value}"
end

def resource_path(resource, value=nil)
  "/#{resource}#{"/#{value}" if value}"
end

def img_url(isbn)
  "https://secure.syndetics.com/index.aspx?isbn=#{isbn}/sc.gif"
end

def normalize_word(raw_word)
  # NB. `str[/.+/]` is my version of Active Support's `str.presence`
  if (word = raw_word.downcase.gsub(/[^a-z]/, '')[/.+/])
    settings.stemmer.stem(word)
  end
end

def my_books
  # TODO - scope books to some kind of user
  @my_books ||= Book.not_skipped
end

def authors_book_counts
  @authors_book_counts ||= my_books.author_books.all(order: :author_value)
    .inject({}) { |h, author_book|
      author_value = author_book.author_value
      count = h[author_value] || 0
      print 'a'
      h.update(author_value => count+1)
    }
    # sort by count...
    # .sort_by { |k, v| [0 - v, k] }
    # .to_h
end

def prc_year_levels_book_counts
  @prc_year_levels_book_counts ||= my_books.book_prc_year_levels.all(order: :prc_year_level_value)
    .inject({}) { |h, book_prc_year_level|
      prc_year_level_value = book_prc_year_level.prc_year_level_value
      count = h[prc_year_level_value] || 0
      print 'p'
      h.update(prc_year_level_value => count+1)
    }
    .sort_by { |k, v| [0 - v, k] }
    .to_h
end

def borrows_book_counts
  @borrows_book_counts ||= my_books.loans.all(order: :issued)
    .inject(Hash.new(0)) { |h, loan|
      print 'b'
      h[loan.issued] += 1
      h
    }
    .to_h
end

def returns_book_counts
  @returns_book_counts ||= my_books.loans.all(order: :returned)
    .inject(Hash.new(0)) { |h, loan|
      print 'r'
      h[loan.returned] += 1
      h
    }
    .to_h
end

def subjects_book_counts
  @subjects_book_counts ||= my_books.book_subjects.all(order: :subject_value)
    .inject(Hash.new(0)) { |h, book_subject|
      subject_value = book_subject.subject_value
      h[subject_value] += 1
      print 's'
      h
    }
end

def normalized_stemmed_words(string)
  settings.stopwords.filter(
    string.split.map { |word| normalize_word(word) }.compact
  )
end

def words_book_counts
  @words_book_counts ||= (my_books.all(:isbn.not => nil) - my_books.all(:main_title.like => '%[sound recording]'))
    .map(&:main_title).compact.inject(Hash.new(0)) { |h, string|
      print 'w'
      normalized_stemmed_words(string).each { |word| h[word] += 1 }
      h
    }
    .sort_by { |k, v| [k, v] }
    .to_h
end

def subject_count
  @subject_count ||= Subject.count
end

def word_cloud_json(resource)
  # See http://mistic100.github.io/jQCloud/#words-options
  settings.send("#{resource}_book_counts").map do |word, count|
    {
      text: word,
      weight: count,
      link: resource_path(resource, word),
      html: {
        title: count
      }
    } if count > MIN_WORD_CLOUD_COUNT
  end.compact.to_json
end



configure do
  set :stopwords, Stopwords::Snowball::Filter.new("en")
  set :stemmer, UEAStemmer.new

  %i(authors subjects prc_year_levels borrows returns words).each do |assoc|
    sym = "#{assoc}_book_counts".to_sym
    set sym, send(sym)
  end
end


get '/' do
  redirect to '/books'
end

get books_path do
  slim :books, locals: { resource: :books, books: books, count: books.count }
end

get '/index.css' do
  cache_control :public, max_age: 600
  sass :style
end

get '/:resource.json' do |resource|
  headers 'Access-Control-Allow-Origin' => '*'
  content_type :json
  Hash[settings.send("#{resource}_book_counts").map { |date, count| [date.to_time.to_i, count] }].to_json
end

RESOURCE_VIEWS.each do |resource, view|
  locals = { resource: resource }
  locals.update(books: books.all(list_saved: true)) if resource == :saved
  get resource_path(resource) do
    slim view, locals: locals
  end
end

get '/books/:value' do |value|
  slim :book, locals: { resource: :books, book: Book.get(value), value: value }
end

get '/:resource/:value' do |resource, value|
  resource = resource.to_sym
  case resource
  when *DATE_RESOURCES
    value = Date.parse(value)
  end

  books = books(resource => value)
  slim :books, locals: {
    resource: resource,
    value: value,
    count: books.count,
    books: books
  }
end

post '/skip_isbn' do
  isbn = params[:isbn]
  # TODO: simpler way?
  if (skipped_isbn = SkippedIsbn.first(value: isbn))
    skipped_isbn.destroy!
  else
    SkippedIsbn.create(value: isbn)
    Book.first(isbn: isbn).destroy
  end
  redirect to books_path
end



__END__


@@ style
$page-header-height: 44px

$border-color: #e9ecef

$book-details-paragraph-font-color: #7e8f9d
$book-details-lite-font-color: #cdcdcd
$book-details-author-font-color: #989898

@mixin tag
  background-color: $border-color
  color: inherit
  display: inline-block
  font-size: .9em
  margin: 4px
  padding: 4px 8px
  text-decoration: none

  &:hover
    background-color: darken($border-color, 5%)

html,
body
  margin: 0
  padding: 0

html
  -moz-osx-font-smoothing: grayscale
  -webkit-font-smoothing: antialiased
  -webkit-tap-highlight-color: transparent
  box-sizing: border-box
  text-size-adjust: 100%

*, *:before, *:after
  box-sizing: inherit

body
  background-color: #f2f5f7
  color: #434f59
  font-family: Helvetica, Arial, sans-serif

.page-header
  background-color: #fff
  height: $page-header-height
  overflow: hidden
  padding: 0 15px

  h1
    display: inline-block
    font: 600 1.5em Quicksand, sans-serif
    margin: 0
    height: 100%
    vertical-align: middle

    &::before
      content: ''
      height: 100%
      display: inline-block
      vertical-align: middle

  @media (max-width: 599px)
    height: 50px

.books
  margin: 0
  padding: 7px
  list-style: none

  @media (min-width: 600px)
    display: flex
    flex-wrap: wrap
    width: 100%

  > li
    display: block
    margin: 7px

    @media (min-width: 600px)
      flex: 1 50%
      max-width: 420px

.book
  background-color: #fff
  border-radius: 4px
  border: 1px solid $border-color
  display: block
  margin: 0
  overflow: hidden

  @media (max-width: 599px)
    text-align: center

  &::after
    clear: both
    content: ''
    display: table

  @media (min-width: 900px)
    width: 100%

.book-cover,
.book-details
  display: block
  width: 100%
  padding: 15px

  @media (min-width: 600px)
    float: left

.book-cover
  width: 100%

  @media (max-width: 599px)
    background-color: #1f2930

  @media (min-width: 600px)
    width: 31.12%

  img
    box-shadow: 0 0 15px #000
    width: 100%

    @media (max-width: 599px)
      max-width: 120px

    @media (min-width: 600px)
      box-shadow: 0 0 8px rgba(0,0,0,.25)

.book-details
  @media (min-width: 600px)
    width: 68.88%

  p
    color: $book-details-paragraph-font-color


.book__title,
.book__author
  @media (max-width: 599px)
    text-align: center

.book__title
  font: 500 1.4em Quicksand, sans-serif
  margin-bottom: 0
  margin-top: 0

  @media (min-width: 600px)
    margin-top: .5em

  a
    color: inherit
    text-decoration: none

.book__author
  color: $book-details-author-font-color
  margin-top: .5em

  [rel="author"]
    color: inherit

.book__subjects
  margin-top: 20px
  font-size: 14px

.subject__title
  display: block

.subject__list
  padding-left: 1.2em

  @media (max-width: 599px)
    margin: 0
    padding: 0
    list-style: none

    > li
      display: inline-block

  [rel="tag"]
    @media (max-width: 599px)
      @include tag

.book__prc_year_levels,
.book__tags,
.book__loans
  border-top: 1px solid $border-color
  clear: both
  padding: 8px 15px
  width: 100%

  [rel="tag"]
    @include tag

  .title
    display: block
    font-size: 13px

.subject__tag
  display: inline-block


@@ _book_short
.book(itemscope itemtype="http://schema.org/Book")
  .book-cover
    a href=books_path(book.id) title=book.main_title
      img src=img_url(get_isbn(book)) alt=book.main_title
    - if !book.book_prc_year_levels.empty?
      a href=resource_path(:prc_year_levels)
        img src="http://www.malvernps.vic.edu.au/wp-content/uploads/prchomepage.gif"
  .book-details
    h2.book__title(itemprop="name")
      a href=books_path(book.id) title=book.main_title = book.main_title
    .book__author(itemprop="author")
      a href=resource_path(:authors) = "by "
      - book.author_books.each do |author_book|
        - author = author_book.author_value
        - book_count = settings.authors_book_counts[author]
        a rel="author" href=resource_path(:authors, author) = (book_count && book_count > 1) ? "#{author} (#{book_count})" : author
        |&nbsp;
== yield if block_given?


@@ _book
== slim(:_book_short, locals: { book: book }) do
  - if !book.book_prc_year_levels.empty?
    .book__prc_year_levels
      span.title
        = "Premier's Reading Challenge - Year Levels:"
      - book.book_prc_year_levels.each do |book_prc_year_level|
        - prc_year_level_value = book_prc_year_level.prc_year_level_value
        a rel="tag" href=resource_path(:prc_year_levels, prc_year_level_value) = prc_year_level_value
        |&nbsp;
  .book__tags
    span.title
      a href=resource_path(:words) = "Title keywords:"
    - normalized_stemmed_words(book.main_title).each do |word|
      a rel="tag" href=resource_path(:words, word)
        = "#{word} (#{settings.words_book_counts[word]})"
    span.title
      a href=resource_path(:subjects) = "Subjects:"
    - book.book_subjects(order: :subject_value).each do |book_subject|
      - subject_value = book_subject.subject_value
      a rel="tag" href=resource_path(:subjects, subject_value)
        = "#{subject_value} (#{settings.subjects_book_counts[subject_value]})"
  - if !book.loans.empty?
    .book__loans
      span.title
        a href=resource_path(:borrows) = "Loan(s):"
      table border=1
        tr
          th
          th borrowed
          th returned
          - book.loans(order: :issued).each_with_index do |loan, index|
            tr
              td = index+1
              td
                a href=resource_path(:borrows, loan.issued) = loan.issued
              td
                a href=resource_path(:returns, loan.returned) = loan.returned


@@ _books
ul.books
  - books.each do |book|
    li
      == slim :_book, locals: { book: book }


@@ _books_short
ul.books
  - books.each do |book|
    li
      == slim :_book_short, locals: { book: book }


@@ book
== slim :_resource_header, locals: locals
== slim :_book, locals: { book: book }
form action="/skip_isbn" method="POST"
  input type="hidden" name="isbn" value=book.isbn
  input type="submit" value="[#{SkippedIsbn.first(value: book.isbn) ? "unskip" : "skip"}]"
table
  - Book.properties.map(&:name).each do |prop|
    tr
      th= prop
      td= book.send(prop)


@@ books
== slim :_resource_header, locals: locals
== slim (params.empty? ? :_books_short : :_books), locals: { books: books }


@@ books_saved
== slim :_resource_header, locals: { resource: resource }
== slim :_books, locals: { books: books.all(list_saved: true) }


@@ _resource_header
header#page-header.page-header
  h1
    | /
    select#slim-single-select0 onChange="document.location.href='/'+this.value"
      - RESOURCE_VIEWS.each do |resource2, view|
        option value=resource2 selected=(resource == resource2) = resource2
    javascript:
      $(function() {
        new SlimSelect({select: '#slim-single-select0'})
      });
    - if defined?(value)
      | /
      select#slim-single-select onChange="document.location.href='/#{resource}/'+this.value"
        - case resource
          - when :books
            - books.each do |book2|
              option value=book2.id selected=(book2.main_title == book.main_title) = book2.main_title
          - else
            - send("#{resource}_book_counts").each do |val, count|
              option value=val selected=(val == value) = "#{val} (#{count} books)"
      javascript:
        $(function() {
          new SlimSelect({select: '#slim-single-select'})
        });


@@ list
== slim :_resource_header, locals: { resource: resource }
- settings.send("#{resource}_book_counts").each do |res, count|
  h2
    a href=resource_path(resource, res) = "#{res} (#{count} books)"


@@ cal_heatmap
== slim :_resource_header, locals: { resource: resource }
#cal-heatmap
button class="btn" id="previousSelector-a-previous" Previous
button class="btn" id="previousSelector-a-next" Next
javascript:
  var cal = new CalHeatMap();
  var date = new Date();
  date.setFullYear( date.getFullYear() - 1 );
  cal.init({
    data: '/#{resource}.json',
    domain: "month",
    itemName: ["book", "books"],
    start: date,
    previousSelector: "#previousSelector-a-previous",
    nextSelector: "#previousSelector-a-next",
    onClick: function(date, count) {
      if (count > 0) {
        var yyyy_mm_dd = date.getFullYear()+'-'+(date.getMonth()+1)+'-'+date.getDate();
        document.location.href='/#{resource}/'+ yyyy_mm_dd
      }
    }
  })


@@ word_cloud
== slim :_resource_header, locals: { resource: resource }
#word_cloud
javascript:
  $(function() {
    $("#word_cloud").jQCloud(
      #{{word_cloud_json(resource)}},
      {
        width: $(window).width(),
        height: ($(window).height() - #{PAGE_HEADER_HEIGHT})
      }
    );
  });


@@ _header


@@ _footer
footer
  small
    - if git_sha
      | github://
      a href="https://github.com/yertto/bookexplorer/commits/#{git_sha}"= git_sha


@@ layout
doctype html
html lang="en"
  head
    title Book Explorer
    meta charset="utf-8"
    meta http-equiv="x-ua-compatible" content="ie=edge"
    meta name="viewport" content="initial-scale=1.0, maximum-scale=1.0, user-scalable=0, width=device-width"
    link href="/index.css" rel="stylesheet" type="text/css"
    link href="https://fonts.googleapis.com/css?family=Quicksand:500" rel="stylesheet"

    link href="/jqcloud.min.css" rel="stylesheet" type="text/css"
    script src="https://code.jquery.com/jquery-3.3.1.min.js"
    script src="/jqcloud.min.js"

    script src="//d3js.org/d3.v3.min.js"
    script src="//cdn.jsdelivr.net/cal-heatmap/3.3.10/cal-heatmap.min.js"
    link rel="stylesheet" href="//cdn.jsdelivr.net/cal-heatmap/3.3.10/cal-heatmap.css"

    link href="/slimselect.min.css" rel="stylesheet" type="text/css"
    script src="/slimselect.min.js"

  body
    == slim :_header
    == yield
    == slim :_footer
