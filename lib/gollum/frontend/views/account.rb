module Precious
  module Views
    class Account < Layout

      attr_reader :email, :fullname, :message

      def title
        "Edit account"
      end

      def has_message
        !@message.nil?
      end
    end
  end
end
