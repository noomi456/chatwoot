class EncryptRealtimekitHookApiTokens < ActiveRecord::Migration[7.1]
  def up
    realtimekit_hooks.find_each do |hook|
      settings = hook.settings.to_h.deep_dup
      token_key = settings.key?('api_token') ? 'api_token' : :api_token
      next unless settings.key?(token_key)

      api_token = settings.delete(token_key)
      hook.update_columns(settings: settings, access_token: api_token.presence, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    realtimekit_hooks.find_each do |hook|
      settings = hook.settings.to_h.deep_dup
      next if settings['api_token'].present? || settings[:api_token].present?
      next if settings['account_id'].blank? && settings[:account_id].blank?

      settings['api_token'] = hook.access_token
      hook.update_columns(settings: settings, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  private

  def realtimekit_hooks
    migration_hook_class.where(app_id: 'dyte')
  end

  def migration_hook_class
    @migration_hook_class ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'integrations_hooks'

      encrypts :access_token, deterministic: true if Chatwoot.encryption_configured?
    end
  end
end
