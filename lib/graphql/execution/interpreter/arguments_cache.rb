# frozen_string_literal: true

module GraphQL
  module Execution
    class Interpreter
      class ArgumentsCache
        def initialize(query)
          @query = query
          @dataloader = query.context.dataloader
          @storage = Hash.new do |h, argument_owner|
            args_by_parent = if argument_owner.arguments_statically_coercible?
              shared_values_cache = {}
              Hash.new do |h2, ignored_parent_object|
                h2[ignored_parent_object] = shared_values_cache
              end
            else
              Hash.new do |h2, parent_object|
                args_by_node = {}
                args_by_node.compare_by_identity
                h2[parent_object] = args_by_node
              end
            end
            args_by_parent.compare_by_identity
            h[argument_owner] = args_by_parent
          end
          @storage.compare_by_identity
        end

        def fetch(ast_node, argument_owner, parent_object)
          # If any jobs were enqueued, run them now,
          # since this might have been called outside of execution.
          # (The jobs are responsible for updating `result` in-place.)
          @dataloader.run_isolated do
            @storage[ast_node][argument_owner][parent_object]
          end
          # Ack, the _hash_ is updated, but the key is eventually
          # overridden with an immutable arguments instance.
          # The first call queues up the job,
          # then this call fetches the result.
          # TODO this should be better, find a solution
          # that works with merging the runtime.rb code
          @storage[ast_node][argument_owner][parent_object]
        end

        # @yield [Interpreter::Arguments, Lazy<Interpreter::Arguments>] The finally-loaded arguments
        def dataload_for(ast_node, argument_owner, parent_object, &block)
          # First, normalize all AST or Ruby values to a plain Ruby hash
          arg_storage = @storage[argument_owner][parent_object]
          if (args = arg_storage[ast_node])
            yield(args)
          else
            args_hash = self.class.prepare_args_hash(@query, ast_node)
            argument_owner.coerce_arguments(parent_object, args_hash, @query.context) do |resolved_args|
              arg_storage[ast_node] = resolved_args
              yield(resolved_args)
            end
          end
          nil
        end

        private

        NO_ARGUMENTS = {}.freeze

        NO_VALUE_GIVEN = Object.new

        def self.prepare_args_hash(query, ast_arg_or_hash_or_value)
          case ast_arg_or_hash_or_value
          when Hash
            if ast_arg_or_hash_or_value.empty?
              return NO_ARGUMENTS
            end
            args_hash = {}
            ast_arg_or_hash_or_value.each do |k, v|
              args_hash[k] = prepare_args_hash(query, v)
            end
            args_hash
          when Array
            ast_arg_or_hash_or_value.map { |v| prepare_args_hash(query, v) }
          when GraphQL::Language::Nodes::Field, GraphQL::Language::Nodes::InputObject, GraphQL::Language::Nodes::Directive
            if ast_arg_or_hash_or_value.arguments.empty?
              return NO_ARGUMENTS
            end
            args_hash = {}
            ast_arg_or_hash_or_value.arguments.each do |arg|
              v = prepare_args_hash(query, arg.value)
              if v != NO_VALUE_GIVEN
                args_hash[arg.name] = v
              end
            end
            args_hash
          when GraphQL::Language::Nodes::VariableIdentifier
            if query.variables.key?(ast_arg_or_hash_or_value.name)
              variable_value = query.variables[ast_arg_or_hash_or_value.name]
              prepare_args_hash(query, variable_value)
            else
              NO_VALUE_GIVEN
            end
          when GraphQL::Language::Nodes::Enum
            ast_arg_or_hash_or_value.name
          when GraphQL::Language::Nodes::NullValue
            nil
          else
            ast_arg_or_hash_or_value
          end
        end
      end
    end
  end
end
