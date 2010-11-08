module Precious
  module Views
    class Login < Layout

      attr_reader :email, :password, :fullname, :message

      def title
        "Login"
      end

      def has_message
        !@message.nil?
      end
    end
  end
end
