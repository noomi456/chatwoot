json.id resource.id
json.name resource.name
json.description resource.description
json.thumbnail resource.avatar_url
json.outgoing_url resource.outgoing_url unless resource.system_bot? || resource.chatring_assistant?
json.bot_type resource.bot_type
json.bot_config resource.bot_config
json.account_id resource.account_id
json.access_token resource.access_token if resource.access_token.present? && !resource.chatring_assistant? && Current.account_user&.administrator?
json.secret resource.secret if !resource.system_bot? && !resource.chatring_assistant? && Current.account_user&.administrator?
json.system_bot resource.system_bot?
