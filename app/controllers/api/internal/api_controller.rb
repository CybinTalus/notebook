module Api
  module Internal
    class ApiController < ApplicationController
      before_action :sanitize_content_type
      before_action :set_content

      def name_lookup
        render body: @content.name, content_type: 'text/plain'
      end

      private

      def sanitize_content_type
        unless Rails.application.config.content_types[:all].map(&:name).include?(params[:page_type])
          raise "Invalid page type: #{params[:page_type]}"
        end

        @sanitized_content_type = params[:page_type].constantize
      end

      def set_content
        @content = @sanitized_content_type.find_by(id: params[:page_id])
      end
    end
  end
end