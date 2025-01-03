Rails.application.routes.draw do
  root to: redirect('/good_job')
  mount GoodJob::Engine => "/good_job"

  get :create_job, to: 'application#create_job'

  mount PgHero::Engine, at: "pghero" if defined?(PgHero)
end
