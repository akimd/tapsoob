#!/usr/bin/env ruby

require 'rubygems'
require 'fileutils'
require 'sequel'
require 'tempfile'
require 'thor'

# tapsoob deps
require 'tapsoob/config'
require 'tapsoob/log'
require 'tapsoob/operation'
require 'tapsoob/schema'
require 'tapsoob/version'

Tapsoob::Config.tapsoob_database_url = ENV['TAPSOOB_DATABASE_URL'] || begin
  # this is dirty but it solves a weird problem where the tempfile disappears mid-process
  #require ((RUBY_PLATFORM =~ /java/).nil? ? 'sqlite3' : 'jdbc-sqlite3')
  $__taps_database = Tempfile.new('tapsoob.db')
  $__taps_database.open()
  "sqlite://#{$__taps_database.path}"
end

module Tapsoob
  module CLI
    class Schema < Thor
      desc "console DATABASE_URL", "Create an IRB REPL connected to a database"
      def console(database_url)
        $db = Sequel.connect(database_url)
        require 'irb'
        require 'irb/completion'
        IRB.start
      end

      desc "dump DATABASE_URL", "Dump a database using a database URL"
      def dump(database_url)
        puts Tapsoob::Schema.dump(database_url)
      end

      desc "dump_table DATABASE_URL TABLE", "Dump a table from a database using a database URL"
      def dump_table(database_url, table)
        puts Tapsoob::Schema.dump_table(database_url, table)
      end

      desc "indexes DATABASE_URL", "Dump indexes from a database using a database URL"
      def indexes(database_url)
        puts Tapsoob::Schema.indexes(database_url)
      end

      desc "indexes_individual DATABASE_URL", "Dump indexes per table individually using a database URL"
      def indexes_individual(database_url)
        puts Tapsoob::Schema.indexes_individual(database_url)
      end

      desc "reset_db_sequences DATABASE_URL", "Reset database sequences using a database URL"
      def reset_db_sequences(database_url)
        Tapsoob::Schema.reset_db_sequences(database_url)
      end

      desc "load DATABASE_URL FILENAME", "Load a database schema from a file to a database using a database URL"
      def load(database_url, filename)
        schema = File.read(filename) rescue help
        Tapsoob::Schema.load(database_url, schema)
      end

      desc "load_indexes DATABASE_URL FILENAME", "Load indexes from a file to a database using a database URL"
      def load_indexes(database_url, filename)
        indexes = File.read(filename) rescue help
        Tapsoob::Schema.load_indexes(database_url, indexes)
      end
    end

    class Root < Thor
      desc "pull DUMP_PATH DATABASE_URL", "Pull a dump from a database to a folder"
      option :"skip-schema", desc: "Don't transfer the schema just data", default: false, type: :boolean, aliases: "-s"
      option :"indexes-first", desc: "Transfer indexes first before data", default: false, type: :boolean, aliases: "-i"
      option :resume, desc: "Resume a Tapsoob Session from a stored file", type: :string, aliases: "-r"
      option :chunksize, desc: "Initial chunksize", default: 1000, type: :numeric, aliases: "-c"
      option :"disable-compression", desc: "Disable Compression", default: false, type: :boolean, aliases: "-g"
      option :filter, desc: "Regex Filter for tables", type: :string, aliases: "-f"
      option :tables, desc: "Shortcut to filter on a list of tables", type: :array, aliases: "-t"
      option :"exclude-tables", desc: "Shortcut to exclude a list of tables", type: :array, aliases: "-e"
      option :debug, desc: "Enable debug messages", default: false, type: :boolean, aliases: "-d"
      def pull(dump_path, database_url)
        opts = parse_opts(options)
        Tapsoob.log.level = Logger::DEBUG if opts[:debug]
        if opts[:resume_filename]
          clientresumexfer(:pull, dump_path, database_url, opts)
        else
          clientxfer(:pull, dump_path, database_url, opts)
        end
      end

      desc "push DUMP_PATH DATABASE_URL", "Push a previously tapsoob dump to a database"
      option :"skip-schema", desc: "Don't transfer the schema just data", default: false, type: :boolean, aliases: "-s"
      option :"indexes-first", desc: "Transfer indexes first before data", default: false, type: :boolean, aliases: "-i"
      option :resume, desc: "Resume a Tapsoob Session from a stored file", type: :string, aliases: "-r"
      option :chunksize, desc: "Initial chunksize", default: 1000, type: :numeric, aliases: "-c"
      option :"disable-compression", desc: "Disable Compression", default: false, type: :boolean, aliases: "-g"
      option :filter, desc: "Regex Filter for tables", type: :string, aliases: "-f"
      option :tables, desc: "Shortcut to filter on a list of tables", type: :array, aliases: "-t"
      option :"exclude-tables", desc: "Shortcut to exclude a list of tables", type: :array, aliases: "-e"
      option :debug, desc: "Enable debug messages", default: false, type: :boolean, aliases: "-d"
      def push(dump_path, database_url)
        opts = parse_opts(options)
        Tapsoob.log.level = Logger::DEBUG if opts[:debug]
        if opts[:resume_filename]
          clientresumexfer(:push, dump_path, database_url, opts)
        else
          clientxfer(:push, dump_path, database_url, opts)
        end
      end

      desc "version", "Show tapsoob version"
      def version
        puts Tapsoob::VERSION.dup
      end

      desc "schema SUBCOMMAND ...ARGS", "Direct access to Tapsoob::Schema class methods"
      subcommand "schema", Schema

      private
        def parse_opts(options)
          # Default options
          opts = {
            skip_schema: options[:"skip-schema"],
            indexes_first: options[:"indexes_first"],
            disable_compression: options[:"disable-compression"],
            debug: options[:debug]
          }

          # Resume
          if options[:resume]
            if File.exists?(options[:resume])
              opts[:resume_file] = options[:resume]
            else
              raise "Unable to find resume file."
            end
          end

          # Default chunksize
          if options[:chunksize]
            opts[:default_chunksize] = (options[:chunksize] < 10 ? 10 : options[:chunksize])
          end

          # Regex filter
          opts[:table_filter] = options[:filter] if options[:filter]

          # Table filter
          if options[:tables]
            r_tables = options[:tables].collect { |t| "^#{t}" }.join("|")
            opts[:table_filter] = "#{r_tables}"
          end

          # Exclude tables
          opts[:exclude_tables] = options[:"exclude-tables"] if options[:"exclude-tables"]

          opts
        end

        def clientxfer(method, dump_path, database_url, opts)
          Tapsoob::Config.verify_database_url(database_url)

          FileUtils.mkpath "#{dump_path}/schemas"
          FileUtils.mkpath "#{dump_path}/data"
          FileUtils.mkpath "#{dump_path}/indexes"

          require 'tapsoob/operation'

          Tapsoob::Operation.factory(method, database_url, dump_path, opts).run
        end

        def clientresumexfer(method, dump_path, database_url, opts)
          session = JSON.parse(File.read(opts.delete(:resume_filename)))
          session.symbolize_recursively!

          dump_path = dump_path || session.delete(:dump_path)

          require 'taps/operation'

          newsession = session.merge({
            :default_chunksize => opts[:default_chunksize],
            :disable_compression => opts[:disable_compression],
            :resume => true
          })

          Tapsoob::Operation.factory(method, database_url, dump_path, newsession).run
        end
    end
  end
end
