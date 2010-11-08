require 'cgi'
require 'sinatra'
require 'gollum'
require 'mustache/sinatra'
require 'digest/sha1'
require 'sqlite3'

require 'gollum/frontend/views/layout'
require 'gollum/frontend/views/editable'

module Precious
  class App < Sinatra::Base
    register Mustache::Sinatra

    dir = File.dirname(File.expand_path(__FILE__))

    # We want to serve public assets for now

    set :public,    "#{dir}/public"
    set :static,    true

    set :mustache, {
      # Tell mustache where the Views constant lives
      :namespace => Precious,

      # Mustache templates live here
      :templates => "#{dir}/templates",

      # Tell mustache where the views are
      :views => "#{dir}/views"
    }

    # for the user auth thing
    enable :sessions

    # Sinatra error handling
    configure :development, :staging do
      set :raise_errors, false
      set :show_exceptions, true
      set :dump_errors, true
      set :clean_trace, false
    end

    get '/' do
      show_page_or_file('Home')
    end

    get '/login' do
      mustache :login
    end

    post '/login' do
      begin
        if params[:register] == 'Register' then
            validate_user
            add_user(params[:email], params[:fullname], params[:password])
            auth_user(params[:email], params[:password])

        elsif params[:login] == 'Login' then
          auth_user(params[:email], params[:password])
        end
      rescue Exception => e
        @message = e.message
      end

      if @message then
        mustache :login
      else redirect '/' end
    end

    get '/logout' do
      session['email'] = session['fullname'] = nil
      redirect '/'
    end

    get '/account' do
      redirect '/login' if !get_auth_user

      @email = session['email']
      @fullname = session['name']

      mustache :account
    end

    post '/account' do
      redirect '/login' if !get_auth_user

      begin
        if params[:update] == 'Update' then
          validate_user(true)
          update_user(session['email'], params[:fullname], params[:password])
          @message = "User data successfully updated"

        elsif params[:delete] == 'Yes!' then
          rm_user(session['email'])
          redirect '/'
        end
      rescue Exception => e
        @message = e.message
      end

      @email = session['email']
      @fullname = session['name']
      mustache :account
    end

    get '/edit/*' do
      redirect '/login' if !get_auth_user

      @name = params[:splat].first
      wiki = Gollum::Wiki.new(settings.gollum_path)
      if page = wiki.page(@name)
        @page = page
        @content = page.raw_data
        mustache :edit
      else
        mustache :create
      end
    end

    post '/edit/*' do
      redirect '/login' if !get_auth_user

      name   = params[:splat].first
      wiki   = Gollum::Wiki.new(settings.gollum_path)
      page   = wiki.page(name)
      format = params[:format].intern
      name   = params[:rename] if params[:rename]

      wiki.update_page(page, name, format, params[:content], commit_data)

      redirect "/#{CGI.escape(Gollum::Page.cname(name))}"
    end

    post '/create/*' do
      redirect '/login' if !get_auth_user

      name = params[:page]
      wiki = Gollum::Wiki.new(settings.gollum_path)

      format = params[:format].intern

      begin
        wiki.write_page(name, format, params[:content], commit_data)
        redirect "/#{CGI.escape(name)}"
      rescue Gollum::DuplicatePageError => e
        @message = "Duplicate page: #{e.message}"
        mustache :error
      end
    end

    post '/preview' do
      format = params['wiki_format']
      data = params['text']
      wiki = Gollum::Wiki.new(settings.gollum_path)
      wiki.preview_page("Preview", data, format).formatted_data
    end

    get '/history/:name' do
      @name     = params[:name]
      wiki      = Gollum::Wiki.new(settings.gollum_path)
      @page     = wiki.page(@name)
      @page_num = [params[:page].to_i, 1].max
      @versions = @page.versions :page => @page_num
      mustache :history
    end

    post '/compare/:name' do
      @versions = params[:versions] || []
      if @versions.size < 2
        redirect "/history/#{CGI.escape(params[:name])}"
      else
        redirect "/compare/%s/%s...%s" % [
          CGI.escape(params[:name]),
          @versions.last,
          @versions.first]
      end
    end

    get '/compare/:name/:version_list' do
      @name     = params[:name]
      @versions = params[:version_list].split(/\.{2,3}/)
      wiki      = Gollum::Wiki.new(settings.gollum_path)
      @page     = wiki.page(@name)
      diffs     = wiki.repo.diff(@versions.first, @versions.last, @page.path)
      @diff     = diffs.first
      mustache :compare
    end

    get %r{/(.+?)/([0-9a-f]{40})} do
      name = params[:captures][0]
      wiki = Gollum::Wiki.new(settings.gollum_path)
      if page = wiki.page(name, params[:captures][1])
        @page = page
        @name = name
        @content = page.formatted_data
        mustache :page
      else
        halt 404
      end
    end

    get '/search' do
      @query = params[:q]
      wiki = Gollum::Wiki.new(settings.gollum_path)
      @results = wiki.search @query
      mustache :search
    end

    get '/*' do
      show_page_or_file(params[:splat].first)
    end

    def show_page_or_file(name)
      wiki = Gollum::Wiki.new(settings.gollum_path)
      if page = wiki.page(name)
        @page = page
        @name = name
        @content = page.formatted_data
        @is_logged_in = !get_auth_user.nil?
        mustache :page
      elsif file = wiki.file(name)
        content_type file.mime_type
        file.raw_data
      else
        redirect '/login' if !get_auth_user
        @name = name
        mustache :create
      end
    end

    def commit_data
      { :name => session['name'],
        :email => session['email'],
        :message => params[:message] }
    end

    def validate_user(update=false)
      if !update then
          unit = '[0-9a-zA-Z_\-\+\.]+'
          # lousy email validator
          raise ArgumentError, "Invalid email"  unless
            params[:email] =~ /^#{unit}\@#{unit}\.#{unit}$/
      end
      raise ArgumentError, "Password too short" if params[:password].size < 5
      raise ArgumentError, "Passwords don't match" if
        params[:password] != params[:passwordagain]
      raise ArgumentError, "Empty name" if params[:fullname] == ''
    end

    def db_factory
      SQLite3::Database.new(settings.gollum_path + '/users.db') rescue
        raise "Could not open database file."
    end

    def password_salt(email, password)
      Digest::SHA1.hexdigest("#{email}-#{password}")
    end

    def touch_users_table
      return true if File.exists?(settings.gollum_path + '/users.db')

      ignored = []
      begin
          open(settings.gollum_path + '/.gitignore') do |f|
            ignored = f.read.grep(/users\.db/)
          end
      rescue ;end

      # add the users database to gitignore
      open(settings.gollum_path + '/.gitignore', 'a') do |f|
        f.write "users.db\n"
      end if ignored.size == 0

      db = db_factory
      sql =
      "create table users (
        email varchar2(254),
        fullname varchar2(63),
        password varchar2(41),
        UNIQUE(email)
      )"

      db.execute(sql) rescue raise "Couldn't create users table"
      db.close
    end

    def add_user(email, fullname, password)
      touch_users_table
      sha1 = password_salt(email, password)
      sql = "insert into users values (?, ?, ?)"

      db = db_factory
      db.transaction do |d|
          begin
            d.execute(sql, email, fullname, sha1)
          rescue StandardError => e
            raise "Could not add user: #{e.message}"
          end
      end
      db.close
    end

    def update_user(email, fullname, password)
      sha1 = password_salt(email, password)
      sql = "update users set(fullname=?, password=?) where email=?"
      db = db_factory
      begin
        db.transaction do |d|
          d.execute(sql, fullname, sha1)
        end
        session['name'] = fullname
      rescue StandardError => e
        raise "Could not update user: #{e.message}"
      end
    end

    def rm_user(email)
      sql = "delete from users where email=?"
      db = db_factory
      begin
        db.transaction do |d|
          d.execute(sql, email)
        end
        session['email'] = session['name'] = nil
      rescue StandardError => e
        raise "Could not delete user: #{e.message}"
      end
    end

    def auth_user(email, password)
      touch_users_table
      sql = "select * from users where email = ? and password = ?"
      sha1 = password_salt(email, password)

      db = db_factory
      row = db.get_first_row(sql, email, sha1)
      if row and row[0] == email then
        session['email'] = email
        session['name'] = row[1]
      else raise "Authentication failed!" end

      db.close
    end

    def get_auth_user
      return nil if !session['email']
      return { :email => session['email'], :name => session['fullname'] }
    end

  end
end
