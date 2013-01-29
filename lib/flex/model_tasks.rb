require 'flex/tasks'

module Flex
  class ModelTasks < Flex::Tasks

    attr_reader :options

    def initialize(overrides={})
      options = Flex::Utils.env2options *default_options.keys

      options[:timeout]    = options[:timeout].to_i      if options[:timeout]
      options[:batch_size] = options[:batch_size].to_i   if options[:batch_size]
      options[:index]      = options[:index].split(',')  if options[:index]
      options[:models]     = options[:models].split(',') if options[:models]

      if options[:import_options]
        import_options = {}
        options[:import_options].split('&').each do |pair|
          k, v  = pair.split('=')
          import_options[k.to_sym] = v
        end
        options[:import_options] = import_options
      end

      @options = default_options.merge(options).merge(overrides)
    end

    def default_options
      @default_options ||= { :force          => false,
                             :timeout        => 20,
                             :batch_size     => 1000,
                             :import_options => { },
                             :index          => Conf.variables[:index],
                             :models         => Conf.flex_models,
                             :config_file    => Conf.config_file,
                             :verbose        => true }
    end

    def import_models
      Conf.http_client.options[:timeout] = options[:timeout]
      deleted = []
      models.each do |klass|
        index = klass.flex.index
        next unless options[:index].include?(index)

        if options[:force]
          unless deleted.include?(index)
            delete_index(index)
            deleted << index
            puts "#{index} index deleted" if options[:verbose]
          end
        end

        unless exist?(index)
          create(index)
          puts "#{index} index created" if options[:verbose]
        end

        if defined?(Mongoid::Document) && klass.include?(Mongoid::Document)
          def klass.find_in_batches(options={})
            0.step(count, options[:batch_size]) do |offset|
              yield limit(options[:batch_size]).skip(offset).to_a
            end
          end
        end

        unless klass.respond_to?(:find_in_batches)
          Conf.logger.error "Class #{klass} does not respond to :find_in_batches. Skipped."
          next
        end

        pbar = ProgBar.new(klass.count, options[:batch_size], "Class #{klass}: ")

        klass.find_in_batches(:batch_size => options[:batch_size]) do |array|
          opts   = {:index => index}.merge(options[:import_options])
          result = Flex.import_collection(array, opts) || next
          pbar.process_result(result, array.size)
        end

        pbar.finish
      end
    end

    def config_hash
      @config_hash ||= begin
                         default = {}.extend Struct::Mergeable
                         Conf.flex_models.each do |m|
                           m = eval"::#{m}" if m.is_a?(String)
                           default.deep_merge! m.flex.get_default_mapping
                         end
                         default.deep_merge(super)
                       end
    end

    private

    def models
      @models ||= begin
                    models = options[:models] || Conf.flex_models
                    raise ArgumentError, 'no class defined. Please use MODELS=ClassA,ClassB ' +
                                         'or set the Flex::Configuration.flex_models properly' \
                                         if models.nil? || models.empty?
                    models.map{|c| c.is_a?(String) ? eval("::#{c}") : c}
                  end
    end

  end

end