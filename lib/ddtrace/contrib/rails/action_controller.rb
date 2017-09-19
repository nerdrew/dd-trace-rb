require 'ddtrace/ext/http'
require 'ddtrace/ext/errors'

module Datadog
  module Contrib
    module Rails
      # Code used to create and handle 'rails.action_controller' spans.
      module ActionController
        KEY = 'datadog_actioncontroller'.freeze

        def self.instrument(config)
          @config = config
          # subscribe when the request processing starts
          ::ActiveSupport::Notifications.subscribe('start_processing.action_controller') do |*args|
            start_processing(*args)
          end

          # subscribe when the request processing has been completed
          ::ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
            process_action(*args)
          end
        end

        def self.start_processing(*)
          return if Thread.current[KEY]

          tracer = @config.fetch(:tracer)
          service = @config.fetch(:default_controller_service)
          type = Datadog::Ext::HTTP::TYPE
          tracer.trace('rails.action_controller', service: service, span_type: type)

          Thread.current[KEY] = true
        rescue StandardError => e
          Datadog::Tracer.log.error(e.message)
        end

        def self.process_action(_name, start, finish, _id, payload)
          return unless Thread.current[KEY]
          Thread.current[KEY] = false

          tracer = @config.fetch(:tracer)
          span = tracer.active_span()
          return unless span

          begin
            resource = "#{payload.fetch(:controller)}##{payload.fetch(:action)}"
            span.resource = resource

            # set the parent resource if it's a `rack.request` span
            if !span.parent.nil? && span.parent.name == 'rack.request'
              span.parent.resource = resource
            end

            span.set_tag('rails.route.action', payload.fetch(:action))
            span.set_tag('rails.route.controller', payload.fetch(:controller))

            if payload[:exception].nil?
              # [christian] in some cases :status is not defined,
              # rather than firing an error, simply acknowledge we don't know it.
              status = payload.fetch(:status, '?').to_s
              span.status = 1 if status.starts_with?('5')
            else
              error = payload[:exception]
              if defined?(::ActionDispatch::ExceptionWrapper)
                status = ::ActionDispatch::ExceptionWrapper.status_code_for_exception(error[0])
                status = status ? status.to_s : '?'
              else
                status = '500'
              end
              span.set_error(error) if status.starts_with?('5')
            end
          ensure
            span.start_time = start
            span.finish(finish)
          end
        rescue StandardError => e
          Datadog::Tracer.log.error(e.message)
        end
      end
    end
  end
end
